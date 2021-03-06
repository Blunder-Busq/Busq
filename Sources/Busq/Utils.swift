/**
 Copyright The Blunder Busq Contributors
 SPDX-License-Identifier: AGPL-3.0

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as
 published by the Free Software Foundation, either version 3 of the
 License, or (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
import Foundation

extension FileManager {
    /// Exracts the .ipa zip file at the given URL and signs it with the specified identity, using entitlements for the given teamID.
    /// - Parameters:
    ///   - url: the path of the .ipa to sign
    ///   - identity: the signing identity, either the keychain name, or the SHA-256 of the certificate to use
    ///   - teamID: the team identifier for signing
    ///   - recompress: whether to re-zip the files after signing or just return the extracted URL
    /// - Returns: the resulting signed artifact
    ///
    /// - Note: only implemented on macOS, since it forks `/usr/bin/zip` and `/usr/bin/codesign`;
    /// all other platforms currently throw `CocoaError(.featureUnsupported)`
    public func prepareIPA(_ url: URL, identity: String, teamID: String, recompress: Bool) throws -> URL {
        #if !os(macOS)
        throw CocoaError(.featureUnsupported)
        #else
        let baseDir = URL(fileURLWithPath: UUID().uuidString, isDirectory: true, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory()))

        let outputDir = URL(fileURLWithPath: url.deletingPathExtension().lastPathComponent, isDirectory: true, relativeTo: baseDir)
        try self.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)

        //print("extracting ipa to:", outputDir.path)

        // extract the file

        try shell("/usr/bin/unzip", args: ["-o", "-q", url.path, "-d", outputDir.path])

        print("unzipped to", outputDir.path)
        try signFolder(outputDir, identity: identity, teamID: teamID)

        if !recompress {
            // just upload the output folder directly
            return outputDir
        } else {
            // repackage as an IPA so we can just send a single file
            // surprisingly, this seems to be slower than sending the expanded ipa directly
            let repackaged = outputDir.appendingPathExtension("ipa")
            //print("re-packaging signed ipa to:", repackaged.path)

            // zip cannot trim path components unless it is in the current directoy;
            // so we need to create a bogus script and execute that instead
            let script = """
            #!/bin/sh
            cd '\(outputDir.path)'
            /usr/bin/zip -ru '\(repackaged.path)' Payload
            """

            let zipScript = URL(fileURLWithPath: UUID().uuidString, isDirectory: true, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathExtension("sh")
            try script.write(to: zipScript, atomically: true, encoding: .utf8)

            // doesn't work with sandbox
            // try self.setAttributes([.posixPermissions: NSNumber(value: 0o777)], ofItemAtPath: zipScript.path)

            //print("zipScript:", zipScript.path)
            try shell("/bin/sh", args: [zipScript.path])
            
            return repackaged
        }
        #endif
    }

    /// Codesigns the nested `.app` and `.framework` folders in the given directory.
    ///
    /// - Parameters:
    ///   - outputDir: the folder to scan
    ///   - identity: the identity to pass to the `codesign` tool, which must be available in the keychain
    ///   - teamID: the team ID for signing
    ///   - keychain: the keychain name to use (optional)
    ///   - verify: whether to verify the code signatures after signing
    ///   - overwrite: whether to overrite any signature that may exist; otherwise, an error will occur if the code is already signed
    func signFolder(_ outputDir: URL, identity: String, teamID: String, keychain: String? = nil, verify: Bool = true, overwrite: Bool = true) throws {
        #if !os(macOS)
        throw CocoaError(.featureUnsupported)
        #else
        // get the "Payload" subfolder
        guard let pathEnumerator = self.enumerator(at: outputDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles, errorHandler: { url, error in
            print("error enumerating:", url, error)
            return true
        }) else {
            throw CocoaError(.fileReadUnknown)
        }

        // Get the list of framework and app paths to sign, starting from the shallowest to the depeest
        let signPaths = Array(pathEnumerator)
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "app" || $0.pathExtension == "appex" || $0.pathExtension == "framework" }
            .filter { $0.relativePath.contains("/__MACOSX/") == false } // some apps embed macOS frameworks; these shouldn't be signed
            .sorted(by: { $0.pathComponents.count < $1.pathComponents.count })

        // get the root app path
        guard let appPath = signPaths.first, appPath.pathExtension == "app" else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        // extract the bundle ID from the app's Info.plist so we can set it in the entitlement
        let plistData = try Data(contentsOf: URL(fileURLWithPath: "Info.plist", relativeTo: appPath))
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? NSDictionary else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let appid = plist["CFBundleIdentifier"] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        let xcent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>application-identifier</key>
            <string>\(teamID).\(appid)</string>
            <key>com.apple.developer.team-identifier</key>
            <string>\(teamID)</string>
            <key>get-task-allow</key>
            <true/>
            <key>keychain-access-groups</key>
            <array>
                <string>\(teamID).\(appid)</string>
            </array>
        </dict>
        </plist>
        """

        let entitlementsDir = URL(fileURLWithPath: UUID().uuidString, isDirectory: true, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        try createDirectory(at: entitlementsDir, withIntermediateDirectories: true)

        let xcentPath = URL(fileURLWithPath: "entitlements.xcent", isDirectory: false, relativeTo: entitlementsDir)

        try xcent.write(to: xcentPath, atomically: false, encoding: .utf8)


        // Iterate through the reverse apps/frameworks paths (i.e., start with the deepest), since signing a child after a parent will invalidate the parent's signature: ???If your app contains nested code, such as an app extension, a framework, or a bundled watchOS app, sign each item separately, starting with the most deeply nested executable, and working your way out; then sign your main app last. Don???t include entitlements or profiles when signing frameworks. Including them produces an invalid code signature.???
        for signPath in signPaths.reversed() {

            // sign the code
            //print("signing:", signPath.path)

            var args = [
                "--sign", identity,
                "--timestamp=none",
                "--generate-entitlement-der"
            ]

            if signPath.pathExtension == "app" {
                // args += ["--preserve-metadata=identifier,entitlements,flags"]
            } else if signPath.pathExtension == "appex" {
                // app extension
            } else if signPath.pathExtension == "framework" {
            }

            args += ["--entitlements", xcentPath.path]

            if let keychain = keychain {
                args += ["--keychain", keychain]
            }

            if overwrite {
                args += ["--force"]
            }

            args += ["--strict"]

            args += [signPath.path]

            print("signing with arguments:", args)
            try shell("/usr/bin/codesign", args: args)
        }

        if verify {
            for signPath in signPaths { // verify all
                var verifyArgs = ["-vvvv", "--verify"]
                verifyArgs += ["--strict"]
                verifyArgs += ["--deep"]
                verifyArgs += ["--display"]

                verifyArgs += [signPath.path]

                try shell("/usr/bin/codesign", args: verifyArgs)
            }
        }
        #endif
    }
}

/// Invoke the given command with shell arguments
/// - Parameters:
///   - command: the command to execute
///   - args: the arguments
/// - Throws: an error
/// - Returns: the string output, which is the concatination of standard error and standard output
@discardableResult public func shell(_ command: String, args: [String]) throws -> String {
    #if os(iOS)
    throw CocoaError(.featureUnsupported) // no Process or NSAppleScript on iOS
    #elseif os(macOS)
    // a sandboxed app is not permitted to use Process(), but it can execute scripts via NSAppleScript
    let cmd = command + " " + args.map({ arg in
        arg.contains(" ") ? "\\\"\(arg)\\\"" : arg })
        .joined(separator: " ")
    //print("executing:", cmd)
    let task = NSAppleScript(source: "do shell script \"\(cmd)\"")
    var error: NSDictionary? = nil
    let desc = task?.executeAndReturnError(&error)
    if let error = error {
        // e.g.:
        // NSAppleScriptErrorBriefMessage = "A identifier can\U2019t go after this identifier.";
        // NSAppleScriptErrorMessage = "A identifier can\U2019t go after this identifier.";
        // NSAppleScriptErrorNumber = "-2740";
        // NSAppleScriptErrorRange = "NSRange: {0, 8}";

        let message = error["NSAppleScriptErrorBriefMessage"] as? String
            ?? error["NSAppleScriptErrorMessage"] as? String
            ?? NSLocalizedString("An unknown error occured", comment: "")

        struct ExecutionError : LocalizedError {
            var failureReason: String?
        }
        throw ExecutionError(failureReason: message)
    }
    //print("executed and returned:", desc?.stringValue ?? "null")
    return desc?.stringValue ?? ""
    #else
    let task = Process()
    task.launchPath = command
    task.arguments = args

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    task.launch()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    task.waitUntilExit()

    let exitCode = task.terminationStatus

    let output = String(data: data, encoding: .utf8) ?? ""

    if exitCode != 0 {
        struct TaskFailed : LocalizedError {
            let command: String
            let exitCode: Int32
            let output: String

            public var errorDescription: String? {
                return "The command \"\(command)\" exited with code: \(exitCode): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }

        throw TaskFailed(command: command, exitCode: exitCode, output: output)
    }
    return output
    #endif
}

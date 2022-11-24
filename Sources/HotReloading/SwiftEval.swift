//
//  SwiftEval.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 02/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftEval.swift#156 $
//
//  Basic implementation of a Swift "eval()" including the
//  mechanics of recompiling a class and loading the new
//  version used in the associated injection version.
//  Used as the basis of a new version of Injection.
//

#if arch(x86_64) || arch(i386) || arch(arm64) // simulator/macOS only
import Foundation
#if SWIFT_PACKAGE
import HotReloadingGuts
private let APP_PREFIX = "🔥 "
#else
private let APP_PREFIX = "💉 "
#endif

@objc protocol SwiftEvalImpl {
    @objc optional func evalImpl(_ptr: UnsafeMutableRawPointer)
}

extension NSObject {

    private static var lastEvalByClass = [String: String]()

    @objc public func swiftEval(code: String) -> Bool {
        if let closure = swiftEval("{\n\(code)\n}", type: (() -> ())?.self) {
            closure()
            return true
        }
        return false
    }

    /// eval() for String value
    @objc public func swiftEvalString(contents: String) -> String {
        return swiftEval("""
            "\(contents)"
            """, type: String.self)
    }

    /// eval() for value of any type
    public func swiftEval<T>(_ expression: String, type: T.Type) -> T {
        let oldClass: AnyClass = object_getClass(self)!
        let className = "\(oldClass)"
        let extra = """

            extension \(className) {

                @objc func evalImpl(_ptr: UnsafeMutableRawPointer) {
                    func xprint<T>(_ str: T) {
                        if let xprobe = NSClassFromString("Xprobe") {
                            #if swift(>=4.0)
                            _ = (xprobe as AnyObject).perform(Selector(("xlog:")), with: "\\(str)")
                            #elseif swift(>=3.0)
                            Thread.detachNewThreadSelector(Selector(("xlog:")), toTarget:xprobe, with:"\\(str)" as NSString)
                            #else
                            NSThread.detachNewThreadSelector(Selector("xlog:"), toTarget:xprobe, withObject:"\\(str)" as NSString)
                            #endif
                        }
                    }

                    #if swift(>=3.0)
                    struct XprobeOutputStream: TextOutputStream {
                        var out = ""
                        mutating func write(_ string: String) {
                            out += string
                        }
                    }

                    func xdump<T>(_ arg: T) {
                        var stream = XprobeOutputStream()
                        dump(arg, to: &stream)
                        xprint(stream.out)
                    }
                    #endif

                    let _ptr = _ptr.assumingMemoryBound(to: (\(type)).self)
                    _ptr.pointee = \(expression)
                }
            }

            """

        // update evalImpl to implement expression

        if NSObject.lastEvalByClass[className] != expression {
            do {
                let tmpfile = try SwiftEval.instance.rebuildClass(oldClass: oldClass,
                                            classNameOrFile: className, extra: extra)
                if let newClass = try SwiftEval.instance
                    .loadAndInject(tmpfile: tmpfile, oldClass: oldClass).first {
                    if NSStringFromClass(newClass) != NSStringFromClass(oldClass) {
                        NSLog("Class names different. Have the right class been loaded?")
                    }

                    // swizzle new version of evalImpl onto class

                    let selector = #selector(SwiftEvalImpl.evalImpl(_ptr:))
                    if let newMethod = class_getInstanceMethod(newClass, selector) {
                        class_replaceMethod(oldClass, selector,
                                            method_getImplementation(newMethod),
                                            method_getTypeEncoding(newMethod))
                        NSObject.lastEvalByClass[className] = expression
                    }
                }
            }
            catch {
            }
        }

        // call patched evalImpl to realise expression

        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        bzero(ptr, MemoryLayout<T>.size)
        if NSObject.lastEvalByClass[className] == expression {
            unsafeBitCast(self, to: SwiftEvalImpl.self).evalImpl?(_ptr: ptr)
        }
        let out = ptr.pointee
        ptr.deallocate()
        return out
    }
}

fileprivate extension StringProtocol {
    subscript(range: NSRange) -> String? {
        return Range(range, in: String(self)).flatMap { String(self[$0]) }
    }
    func escaping(_ chars: String, with template: String = "\\$0") -> String {
        return self.replacingOccurrences(of: "[\(chars)]",
            with: template.replacingOccurrences(of: #"\"#, with: "\\\\"),
            options: [.regularExpression])
    }
    func unescape() -> String {
        return replacingOccurrences(of: #"\\(.)"#, with: "$1",
                                    options: .regularExpression)
    }
}

@objc(SwiftEval)
public class SwiftEval: NSObject {

    static var instance = SwiftEval()

    @objc public class func sharedInstance() -> SwiftEval {
        return instance
    }

    @objc public var signer: ((_: String) -> Bool)?
    @objc public var vaccineEnabled: Bool = false

    // client specific info
    @objc public var frameworks = Bundle.main.privateFrameworksPath
                                    ?? Bundle.main.bundlePath + "/Frameworks"
    #if arch(arm64)
    @objc public var arch = "arm64"
    #elseif arch(x86_64)
    @objc public var arch = "x86_64"
    #else
    @objc public var arch = "i386"
    #endif

    var forceUnhide = {}
    var legacyUnhide = false
    var objectUnhider: ((String) -> Void)?
    var linkerOptions = ""

    let skipBazelLinking = "--skip_linking"
    var bazelLight = getenv("INJECTION_BAZEL") != nil ||
            UserDefaults.standard.bool(forKey: "bazelLight")
    let bazelWorkspace = "WORKSPACE"

    /// Additional logging to /tmp/hot\_reloading.log for "HotReloading" version of injection.
    var debug = { (what: Any...) in
        #if SWIFT_PACKAGE
        let log = true
        #else
        let log = getenv("INJECTION_DEBUG") != nil
        #endif
        if log {
            NSLog("\(APP_PREFIX)***** %@", what.map {"\($0)"}.joined(separator: " "))
        }
    }

    // Xcode related info
    @objc public var xcodeDev = "/Applications/Xcode.app/Contents/Developer" {
        willSet(newValue) {
            if newValue != xcodeDev {
                print(APP_PREFIX+"Selecting Xcode \(newValue)")
            }
        }
    }

    @objc public var projectFile: String?
    @objc public var derivedLogs: String?
    @objc public var tmpDir = "/tmp" {
        didSet {
//            SwiftEval.buildCacheFile = "\(tmpDir)/eval_builds.plist"
        }
    }
    @objc public var injectionNumber = 100
    @objc public var lastIdeProcPath = ""

    var tmpfile: String { URL(fileURLWithPath: tmpDir)
        .appendingPathComponent("eval\(injectionNumber)").path }
    var logfile: String { "\(tmpfile).log" }
    var cmdfile: String { URL(fileURLWithPath: tmpDir)
        .appendingPathComponent("command.sh").path
    }

    /// Error handler
    @objc public var evalError = {
        (_ message: String) -> Error in
        print(APP_PREFIX+(message.hasPrefix("Compiling") ?"":"⚠️ ")+message)
        return NSError(domain: "SwiftEval", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    func scriptError(_ what: String) -> Error {
        var log = (try? String(contentsOfFile: logfile)) ??
                    "Could not read log file '\(logfile)'"
        if log.contains(".h' file not found") {
            log += "\(APP_PREFIX)⚠️ Adjust the \"Header Search Paths\" in your project's Build Settings"
        }
        return evalError("""
            \(what) failed (see: \(cmdfile))
            \(log)
            """)
    }

    var compileByClass = [String: (String, String)]()

    static var buildCacheFile = "/tmp/eval_builds.plist"
    static var longTermCache =
        NSMutableDictionary(contentsOfFile: buildCacheFile) ?? NSMutableDictionary()

    public func determineEnvironment(classNameOrFile: String) throws -> (URL, URL) {
        // Largely obsolete section used find Xcode paths from source file being injected.

        let sourceURL = URL(fileURLWithPath:
            classNameOrFile.hasPrefix("/") ? classNameOrFile : #file)
        debug("Project file:", projectFile ?? "nil")
        guard let derivedData = findDerivedData(url: URL(fileURLWithPath:
                    NSHomeDirectory()), ideProcPath: self.lastIdeProcPath) ??
            (self.projectFile != nil ?
                findDerivedData(url: URL(fileURLWithPath:
                        self.projectFile!), ideProcPath: self.lastIdeProcPath) :
                findDerivedData(url: sourceURL, ideProcPath: self.lastIdeProcPath)) else {
                throw evalError("Could not locate derived data. Is the project under your home directory?")
        }
        debug("DerivedData:", derivedData.path)
        guard let (projectFile, logsDir) =
                derivedLogs.flatMap({
                    (findProject(for: sourceURL, derivedData:derivedData)?
                        .projectFile ?? URL(fileURLWithPath: "/tmp/x.xcodeproj"),
                     URL(fileURLWithPath: $0)) }) ??
                projectFile
                    .flatMap({ logsDir(project: URL(fileURLWithPath: $0), derivedData: derivedData) })
                    .flatMap({ (URL(fileURLWithPath: projectFile!), $0) }) ??
                findProject(for: sourceURL, derivedData: derivedData) else {
                    throw evalError("""
                        Could not locate containing project or it's logs.
                        For a macOS app you need to turn off the App Sandbox.
                        Are using a custom DerivedData path? This is not supported.
                        """)
        }

        if false == (try? String(contentsOf: projectFile
            .appendingPathComponent("project.pbxproj")))?.contains("-interposable") {
            print(APP_PREFIX+"""
                ⚠️ Project file does not contain the -interposable linker flag. \
                If you want to be able to inject methods of structs and final classes, \
                please add \"Other Linker Flags\" -Xlinker -interposable.
                """)
        }

        return (projectFile, logsDir)
    }

    @objc public func rebuild(storyboard: String) throws {
        let (_, logsDir) = try determineEnvironment(classNameOrFile: storyboard)

        injectionNumber += 1

        // messy but fast
        guard shell(command: """
            # search through build logs, most recent first
            cd "\(logsDir.path.escaping("$"))" &&
            for log in `ls -t *.xcactivitylog`; do
                #echo "Scanning $log"
                /usr/bin/env perl <(cat <<'PERL'
                    use English;
                    use strict;

                    # line separator in Xcode logs
                    $INPUT_RECORD_SEPARATOR = "\\r";

                    # format is gzip
                    open GUNZIP, "/usr/bin/gunzip <\\"$ARGV[0]\\" 2>/dev/null |" or die;

                    # grep the log until to find codesigning for product path
                    my $realPath;
                    while (defined (my $line = <GUNZIP>)) {
                        if ($line =~ /^\\s*cd /) {
                            $realPath = $line;
                        }
                        elsif (my ($product) = $line =~ m@/usr/bin/ibtool.*? --link (([^\\ ]+\\\\ )*\\S+\\.app)@o) {
                            print $product;
                            exit 0;
                        }
                    }

                    # class/file not found
                    exit 1;
            PERL
                ) "$log" >"\(tmpfile).sh" && exit 0
            done
            exit 1;
            """) else {
            throw scriptError("Locating storyboard compile")
        }

        guard let resources = try? String(contentsOfFile: "\(tmpfile).sh")
            .trimmingCharacters(in: .whitespaces) else {
            throw scriptError("Locating product")
        }

        guard shell(command: """
            (cd "\(resources.unescape().escaping("$"))" && for i in 1 2 3 4 5; \
            do if (find . -name '*.nib' -a -newer "\(storyboard)" | \
            grep .nib >/dev/null); then break; fi; sleep 1; done; \
            while (ps auxww | grep -v grep | grep "/ibtool " >/dev/null); do sleep 1; done; \
            for i in `find . -name '*.nib'`; do cp -rf "$i" "\(
                        Bundle.main.bundlePath)/$i"; done >"\(logfile)" 2>&1)
            """) else {
                throw scriptError("Re-compilation")
        }

        _ = evalError("Copied \(storyboard)")
    }

    public func actualCase(path: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            return path
        }
        var out = ""
        for component in path.split(separator: "/") {
            var real: String?
            if fm.fileExists(atPath: out+"/"+component) {
                real = String(component)
            } else {
                guard let contents = try? fm.contentsOfDirectory(atPath: "/"+out) else {
                    return nil
                }
                real = contents.first { $0.lowercased() == component.lowercased() }
            }

            guard let found = real else {
                return nil
            }
            out += "/" + found
        }
        return out
    }

    let detectFilepaths = try! NSRegularExpression(pattern: #"(/(?:[^\ ]*\\.)*[^\ ]*) "#)

    @objc public func rebuildClass(oldClass: AnyClass?,
        classNameOrFile: String, extra: String?) throws -> String {
        let (projectFile, logsDir) = try
            determineEnvironment(classNameOrFile: classNameOrFile)
        let projectRoot = projectFile.deletingLastPathComponent().path

        // locate compile command for class

        injectionNumber += 1

        if projectFile.lastPathComponent == bazelWorkspace,
            let dylib = try bazelLight(projectRoot: projectRoot,
                                       recompile: classNameOrFile) {
            return dylib
        }

        guard var (compileCommand, sourceFile) = try
            compileByClass[classNameOrFile] ??
            findCompileCommand(logsDir: logsDir,
               classNameOrFile: classNameOrFile, tmpfile: tmpfile) ??
            SwiftEval.longTermCache[classNameOrFile].flatMap({
                ($0 as! String, classNameOrFile) }) else {
            throw evalError("""
                Could not locate compile command for \(classNameOrFile).
                This could be due to one of the following:
                1. Injection does not work with Whole Module Optimization.
                2. There are restrictions on characters allowed in paths.
                3. File paths in the simulator are case sensitive.
                4. The modified source file is not in the current project.
                5. The source file is an XCTest that has not been run yet.
                6. Xcode has removed the build logs. Edit a file and re-run.
                Try a build clean then rebuild to make logs available or
                consult: "\(cmdfile)".
                """)
        }
        sourceFile += "" // remove warning

        #if targetEnvironment(simulator)
        // Normalise paths in compile command with the actual casing
        // of files as the simulator has a case-sensitive file system.
        for filepath in detectFilepaths.matches(in: compileCommand, options: [],
            range: NSMakeRange(0, compileCommand.utf16.count))
            .compactMap({ compileCommand[$0.range(at: 1)] }) {
            let unescaped = filepath.unescape()
            if let normalised = actualCase(path: unescaped) {
                let escaped = normalised.escaping("' ${}()&*~")
                if filepath != escaped {
                    print("""
                            \(APP_PREFIX)Mapped: \(filepath)
                            \(APP_PREFIX)... to: \(escaped)
                            """)
                    compileCommand = compileCommand
                        .replacingOccurrences(of: filepath, with: escaped,
                                              options: .caseInsensitive)
                }
            }
        }
        #endif

        // load and patch class source if there is an extension to add

        let filemgr = FileManager.default, backup = sourceFile + ".tmp"
        if extra != nil {
            guard var classSource = try? String(contentsOfFile: sourceFile) else {
                throw evalError("Could not load source file \(sourceFile)")
            }

            let changesTag = "// extension added to implement eval"
            classSource = classSource.components(separatedBy: "\n\(changesTag)\n")[0] + """

                \(changesTag)
                \(extra!)

                """

            debug(classSource)

            // backup original and compile patched class source

            if !filemgr.fileExists(atPath: backup) {
                try! filemgr.moveItem(atPath: sourceFile, toPath: backup)
            }
            try! classSource.write(toFile: sourceFile, atomically: true, encoding: .utf8)
        }

        defer {
            if extra != nil {
                try! filemgr.removeItem(atPath: sourceFile)
                try! filemgr.moveItem(atPath: backup, toPath: sourceFile)
            }
        }

        // Extract object path (overidden in UnhidingEval.swift for Xcode 13)
        let objectFile = xcode13Fix(sourceFile: sourceFile,
                                    compileCommand: &compileCommand)

        _ = evalError("Compiling \(sourceFile)")

        let isBazelCompile = compileCommand.contains(skipBazelLinking)
        if isBazelCompile, arch == "x86_64", !compileCommand.contains(arch) {
            compileCommand = compileCommand
                .replacingOccurrences(of: #"(--cpu=ios_)\w+"#,
                  with: "$1\(arch)", options: .regularExpression)
        }

        debug("Final command:", compileCommand, "-->", objectFile)
        guard shell(command: """
                (cd "\(projectRoot.escaping("$"))" && \
                \(compileCommand) >\"\(logfile)\" 2>&1)
                """) || isBazelCompile else {
            compileByClass.removeValue(forKey: classNameOrFile)
            throw scriptError("Re-compilation")
        }

        compileByClass[classNameOrFile] = (compileCommand, sourceFile)
        if SwiftEval.longTermCache[classNameOrFile] as? String != compileCommand &&
            classNameOrFile.hasPrefix("/") {
            SwiftEval.longTermCache[classNameOrFile] = compileCommand
            SwiftEval.longTermCache.write(toFile: SwiftEval.buildCacheFile,
                                          atomically: false)
        }

        if isBazelCompile {
            let projectRoot = objectFile // returned by xcode13Fix()
            return try bazelLink(in: projectRoot, since: sourceFile,
                                 compileCommand: compileCommand)
        }

        // link resulting object file to create dynamic library
        _ = objectUnhider?(objectFile)

        var speclib = ""
        if sourceFile.contains("Spec.") {
            let dylib = tmpfile+Self.quickDylib
            do {
                let platform = "\"__PLATFORM__\"/../../"
                let platformLib = platform+"usr/lib"
                let platformFrameworks = platform+"Library/Frameworks"
                try link(dylib: dylib, compileCommand: compileCommand, contents: """
                    \(logsDir.path)/../../Build/Products/\(Self.quickFiles) \
                    \(platformLib)/libXCTestSwiftSupport.dylib \
                    -Xlinker -rpath \(platformLib) \
                    -framework XCTest -F \(platformFrameworks) \
                    -Xlinker -rpath \(platformFrameworks)
                    """)
                speclib = dylib
            } catch {
                debug(APP_PREFIX+"⚠️ Error building support dylib for Quick")
            }
        }

        try link(dylib: "\(tmpfile).dylib", compileCommand: compileCommand,
                 contents: "\"\(objectFile)\" \(speclib)")
        return (speclib != "" ? speclib+Self.dylibDelim : "")+tmpfile
    }

    var moduleLibraries = Set<String>()

    func bazelLink(in projectRoot: String, since sourceFile: String,
                   compileCommand: String) throws -> String {
        guard var objects = bazelFiles(under: projectRoot, where: """
            -newer "\(sourceFile)" -a -name '*.o' | \
            egrep '(_swift_incremental|_objs)/' | grep -v /external/
            """) else {
            throw evalError("Finding Objects failed. Did you actually make a change to \(sourceFile) and does it compile? \(APP_NAME) does not support whole module optimization. (check logfile: \(logfile))")
        }

        debug(bazelLight, projectRoot, objects)
        // precendence to incrementally compiled
        let incremental = objects.filter({ $0.contains("_swift_incremental") })
        if incremental.count > 0 {
            objects = incremental
        }

        #if true
        // With WMO, which modifies all object files
        // we need a way to filter them down to that
        // of the source file and its related module
        // library to provide shared "hidden" symbols.
        // We use the related Swift "output_file_map"
        // for the module name to include its library.
        if objects.count > 1 {
            let objectSet = Set(objects)
            if let maps  = bazelFiles(under: projectRoot,
                                      where: "-name '*output_file_map*.json'") {
                let relativePath = sourceFile .replacingOccurrences(
                    of: projectRoot+"/", with: "")
                for map in maps {
                    if let data = try? Data(contentsOf: URL(
                        fileURLWithPath: projectRoot)
                        .appendingPathComponent(map)),
                       let json = try? JSONSerialization.jsonObject(
                        with: data, options: []) as? [String: Any],
                       let info = json[relativePath] as? [String: String] {
                        if let object = info["object"],
                           objectSet.contains(object) {
                            objects = [object]
                            if let module =
                                map[#"(\w+)\.output_file_map"#] as String? {
                                for lib in bazelFiles(under: projectRoot,
                                    where: "-name 'lib\(module).a'") ?? [] {
                                    moduleLibraries.insert(lib)
                                }
                            }
                            break
                        }
                    }
                }
            } else {
                _ = evalError("Error reading maps")
            }
        }
        #endif

        objects += moduleLibraries
        debug(objects)

        try link(dylib: "\(tmpfile).dylib", compileCommand: compileCommand,
                 contents: objects.map({ "\"\($0)\""}).joined(separator: " "),
                 cd: projectRoot)
        return tmpfile
    }

    func bazelFiles(under projectRoot: String, where clause:  String,
                    ext: String = "files") -> [String]? {
        let list = "\(tmpfile).\(ext)"
        if shell(command: """
            cd "\(projectRoot)" && \
            find bazel-out/* \(clause) >"\(list)" 2>>\"\(logfile)\"
            """), let files = (try? String(contentsOfFile: list))?
            .components(separatedBy: "\n").dropLast() {
            return Array(files)
        }
        return nil
    }

    func bazelLight(projectRoot: String, recompile sourceFile: String) throws -> String? {
        let relativePath = sourceFile.replacingOccurrences(of:
            projectRoot+"/", with: "")
        let bazelRulesSwift = projectRoot +
            "/bazel-out/../external/build_bazel_rules_swift"
        let paramsScanner = tmpDir + "/bazel.pl"
        debug(projectRoot, relativePath, bazelRulesSwift, paramsScanner)

        if !sourceFile.hasSuffix(".swift") {
            throw evalError("Only Swift sources can be standalone injected with bazel")
        }

        try #"""
            use JSON::PP;
            use English;
            use strict;

            my ($params, $relative) = @ARGV;
            my $args = join('', (IO::File->new( "< $params" )
                or die "Could not open response '$params'")->getlines());
            my ($filemap) = $args =~ /"-output-file-map"\n"([^"]+)"/;
            my $file_handle = IO::File->new( "< $filemap" )
                or die "Could not open filemap '$filemap'";
            my $json_text = join'', $file_handle->getlines();
            my $json_map = decode_json( $json_text, { utf8  => 1 } );

            if (my $info = $json_map->{$relative}) {
                $args =~ s/"-(emit-(module|objc-header)-path"\n"[^"]+)"\n//g;
                my $paramscopy = "$params.copy";
                my $paramsfile = IO::File->new("> $paramscopy");
                binmode $paramsfile, ':utf8';
                $paramsfile->print($args);
                $paramsfile->close();
                print "$paramscopy\n$info->{object}\n";
                exit 0;
            }
            # source file not found
            exit 1;
            """#.write(toFile: paramsScanner,
                       atomically: false, encoding: .utf8)

        let errfile = "\(tmpfile).err"
        guard shell(command: """
            # search through bazel args, most recent first
            cd "\(bazelRulesSwift)" 2>"\(errfile)" &&
            grep module_name_ tools/worker/swift_runner.h >/dev/null 2>>"\(errfile)" ||
            (git apply -v <<'BAZEL_PATCH' 2>>"\(errfile)" && echo "⚠️ bazel patched, restart app" >>"\(errfile)" && exit 1) &&
            diff --git a/tools/worker/swift_runner.cc b/tools/worker/swift_runner.cc
            index 535dad0..19e1a6d 100644
            --- a/tools/worker/swift_runner.cc
            +++ b/tools/worker/swift_runner.cc
            @@ -369,6 +369,11 @@ std::vector<std::string> SwiftRunner::ParseArguments(Iterator itr) {
                     arg = *it;
                     output_file_map_path_ = arg;
                     out_args.push_back(arg);
            +      } else if (arg == "-module-name") {
            +        ++it;
            +        arg = *it;
            +        module_name_ = arg;
            +        out_args.push_back(arg);
                   } else if (arg == "-index-store-path") {
                     ++it;
                     arg = *it;
            @@ -410,12 +415,28 @@ std::vector<std::string> SwiftRunner::ProcessArguments(
                 ++it;
               }

            +  auto copy = "/tmp/bazel_"+module_name_+".params";
            +  unlink(copy.c_str());
               if (force_response_file_) {
                 // Write the processed args to the response file, and push the path to that
                 // file (preceded by '@') onto the arg list being returned.
                 auto new_file = WriteResponseFile(response_file_args);
                 new_args.push_back("@" + new_file->GetPath());
            +
            +    // patch to retain swiftc arguments file
            +    link(new_file->GetPath().c_str(), copy.c_str());
                 temp_files_.push_back(std::move(new_file));
            +  } else if (FILE *fp = fopen("/tmp/forced_params.txt", "w+")) {
            +    // alternate patch to capture arguments file
            +    for (auto &a : args_destination) {
            +      const char *carg = a.c_str();
            +      fprintf(fp, "%s\\n", carg);
            +      if (carg[0] != '@')
            +          continue;
            +      link(carg+1, copy.c_str());
            +      fprintf(fp, "Linked %s to %s\\n", copy.c_str(), carg+1);
            +    }
            +    fclose(fp);
               }

               return new_args;
            diff --git a/tools/worker/swift_runner.h b/tools/worker/swift_runner.h
            index 952c593..35cf055 100644
            --- a/tools/worker/swift_runner.h
            +++ b/tools/worker/swift_runner.h
            @@ -153,6 +153,9 @@ class SwiftRunner {
               // The index store path argument passed to the runner
               std::string index_store_path_;

            +  // Swift modue name from -module-name
            +  std::string module_name_ = "Unknown";
            +
               // The path of the global index store  when using
               // swift.use_global_index_store. When set, this is passed to `swiftc` as the
               // `-index-store-path`. After running `swiftc` `index-import` copies relevant
            BAZEL_PATCH

            cd "\(projectRoot)" 2>>"\(errfile)" &&
            for params in `ls -t /tmp/bazel_*.params 2>>"\(errfile)"`; do
                #echo "Scanning $params"
                /usr/bin/env perl "\(paramsScanner)" "$params" "\(relativePath)" \
                >"\(tmpfile).sh" 2>>"\(errfile)" && exit 0
            done
            exit 1;
            """), let returned = (try? String(contentsOfFile: "\(tmpfile).sh"))?
                                        .components(separatedBy: "\n") else {
            if let log = try? String(contentsOfFile: errfile), log != "" {
                throw evalError(log.contains("ls: /tmp/bazel_*.params") ? """
                    \(log)Response files not available (see: \(cmdfile))
                    Edit and save a swift source file and restart app.
                    """ : """
                    Locating response file failed (see: \(cmdfile))
                    \(log)
                    """)
            }
            return nil
        }

        let params = returned[0]
        _ = evalError("Compiling using parameters from \(params)")

        guard shell(command: """
                cd "\(projectRoot)" && \
                chmod +w `find bazel-out/* -name '*.o'`; \
                xcrun swiftc @\(params) >\"\(logfile)\" 2>&1
                """) || shell(command: """
                cd `readlink "\(projectRoot)/bazel-out"`/.. && \
                chmod +w `find bazel-out/* -name '*.o'`; \
                xcrun swiftc @\(params) >>\"\(logfile)\" 2>&1
                """),
              let compileCommand = try? String(contentsOfFile: params) else {
            throw scriptError("Recompiling")
        }

        return try bazelLink(in: projectRoot, since: sourceFile,
                             compileCommand: compileCommand)
    }

    static let quickFiles = getenv("INJECTION_QUICK_FILES").flatMap {
        String(cString: $0) } ?? "Debug-*/{Quick*,Nimble,Cwl*}.o"
    static let quickDylib = "_spec.dylib"
    static let dylibDelim = "==="
    static let parsePlatform = try! NSRegularExpression(pattern:
        #"-(?:isysroot|sdk)(?: |"\n")((\#(fileNameRegex)/Contents/Developer)/Platforms/(\w+)\.platform\#(fileNameRegex)\#\.sdk)"#)

    func link(dylib: String, compileCommand: String, contents: String,
              cd: String = "") throws {
        var platform = "iPhoneSimulator"
        var sdk = "\(xcodeDev)/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk"
        if let match = Self.parsePlatform.firstMatch(in: compileCommand,
            options: [], range: NSMakeRange(0, compileCommand.utf16.count)) {
            func extract(group: Int, into: inout String) {
                if let range = Range(match.range(at: group), in: compileCommand) {
                    into = compileCommand[range]
                        .replacingOccurrences(of: #"\\(.)"#, with: "$1",
                                              options: .regularExpression)
                }
            }
            extract(group: 1, into: &sdk)
            extract(group: 2, into: &xcodeDev)
            extract(group: 4, into: &platform)
        } else if compileCommand.contains(" -o ") {
            _ = evalError("Unable to parse SDK from: \(compileCommand)")
        }

        var osSpecific = ""
        switch platform {
        case "iPhoneSimulator":
            osSpecific = "-mios-simulator-version-min=9.0"
        case "iPhoneOS":
            osSpecific = "-miphoneos-version-min=9.0"
        case "AppleTVSimulator":
            osSpecific = "-mtvos-simulator-version-min=9.0"
        case "AppleTVOS":
            osSpecific = "-mtvos-version-min=9.0"
        case "MacOSX":
            let target = compileCommand
                .replacingOccurrences(of: #"^.*( -target \S+).*$"#,
                                      with: "$1", options: .regularExpression)
            osSpecific = "-mmacosx-version-min=10.11"+target
        default:
            _ = evalError("Invalid platform \(platform)")
            // -Xlinker -bundle_loader -Xlinker \"\(Bundle.main.executablePath!)\""
        }

        let toolchain = xcodeDev+"/Toolchains/XcodeDefault.xctoolchain"
        let cd = cd == "" ? "" : "cd \"\(cd)\" && "
        if cd != "" && !contents.contains(arch) {
            _ = evalError("Modified object files \(contents) not built for architecture \(arch)")
        }
        guard shell(command: """
            \(cd)"\(toolchain)/usr/bin/clang" -arch "\(arch)" \
                -Xlinker -dylib -isysroot "__PLATFORM__" \
                -L"\(toolchain)/usr/lib/swift/\(platform.lowercased())" \(osSpecific) \
                -undefined dynamic_lookup -dead_strip -Xlinker -objc_abi_version \
                -Xlinker 2 -Xlinker -interposable\(linkerOptions) -fobjc-arc \
                -fprofile-instr-generate \(contents) -L "\(frameworks)" -F "\(frameworks)" \
                -rpath "\(frameworks)" -o \"\(dylib)\" >>\"\(logfile)\" 2>&1
            """.replacingOccurrences(of: "__PLATFORM__", with: sdk)) else {
            throw scriptError("Linking")
        }

        // codesign dylib

        if signer != nil {
            guard dylib.hasSuffix(Self.quickDylib) ||
                signer!("\(injectionNumber).dylib") else {
                #if SWIFT_PACKAGE
                throw evalError("Codesign failed. Consult /tmp/hot_reloading.log")
                #else
                throw evalError("Codesign failed. If you are using macOS 11+, Please download a new release from https://github.com/johnno1962/InjectionIII/releases")
                #endif
            }
        }
        else {
            #if os(iOS)
            // have to delegate code signing to macOS "signer" service
            guard (try? String(contentsOf: URL(string: "http://localhost:8899\(tmpfile).dylib")!)) != nil else {
                throw evalError("Codesign failed. Is 'signer' daemon running?")
            }
            #else
            guard shell(command: """
                export CODESIGN_ALLOCATE=\(xcodeDev)/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate; codesign --force -s '-' "\(tmpfile).dylib"
                """) else {
                throw evalError("Codesign failed")
            }
            #endif
        }

        // Rewrite dylib to prevent macOS 10.15+ from quarantining it
        let url = URL(fileURLWithPath: dylib)
        let dylib = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try dylib.write(to: url)
    }


    /// Regex for path argument, perhaps containg escaped spaces
    static let argumentRegex = #"[^\s\\]*(?:\\.[^\s\\]*)*"#
    /// Regex to extract filename base, perhaps containg escaped spaces
    static let fileNameRegex = #"/(\#(argumentRegex))\.\w+"#
    /// Extract full file path and name either quoted or escaped
    static let filePathRegex =
            #""/[^"]*\#(fileNameRegex)"|/\#(argumentRegex)"#

    // Overridden in  UnhidingEval.swift
    func xcode13Fix(sourceFile: String,
                    compileCommand: inout String) -> String {
        // Trim off junk at end of compile command
        if sourceFile.hasSuffix(".swift") {
            compileCommand = compileCommand.replacingOccurrences(
                of: " -o (\(Self.filePathRegex))",
                with: "", options: .regularExpression)
                .components(separatedBy: " -index-system-modules")[0]
        } else {
            compileCommand = compileCommand
                .components(separatedBy: " -o ")[0]
        }
        if compileCommand.contains("/bazel ") {
            // force ld to fail as it is not needed
            compileCommand += " --linkopt=-Wl,"+skipBazelLinking
            // return path to workspace instead of object file
            return compileCommand[#"^cd "([^"]+)""#] ?? "dir?"
        }
        compileCommand += " -o \(tmpfile).o"
        return tmpfile+".o"
    }

    func createUnhider(executable: String, _ objcClassRefs: NSMutableArray,
                       _ descriptorRefs: NSMutableArray) {
    }

    lazy var loadXCTest: () = {
        #if os(macOS)
        let sdk = "MacOSX"
        #elseif os(tvOS)
        let sdk = "AppleTVSimulator"
        #elseif targetEnvironment(simulator)
        let sdk = "iPhoneSimulator"
        #else
        let sdk = "iPhoneOS"
        #endif

        let platform = "\(xcodeDev)/Platforms/\(sdk).platform/Developer/"

        if dlopen(platform+"Library/Frameworks/XCTest.framework/XCTest", RTLD_LAZY) == nil {
            debug(String(cString: dlerror()))
        }
        if dlopen(platform+"usr/lib/libXCTestSwiftSupport.dylib", RTLD_LAZY) == nil {
            debug(String(cString: dlerror()))
        }
    }()

    lazy var loadTestsBundle: () = {
        do {
            guard let testsBundlePath = try testsBundlePath() else {
                debug("Tests bundle wasn't found - did you run the tests target before running the application?")
                return
            }
            guard let bundle = Bundle(path: testsBundlePath), bundle.load() else {
                debug("Failed loading tests bundle")
                return
            }
        } catch {
            debug("Error while searching for the tests bundle: \(error)")
            return
        }
    }()

    func testsBundlePath() throws -> String? {
        guard let pluginsDirectory = Bundle.main.path(forResource: "PlugIns", ofType: nil) else {
            return nil
        }

        let bundlePaths: [String] = try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory)
            .filter { $0.hasSuffix(".xctest") }
            .map { directoryName in
                return "\(pluginsDirectory)/\(directoryName)"
            }
        if bundlePaths.count > 1 {
            debug("Found more than one tests bundle, using the first one")
        }
        return bundlePaths.first
    }

    @objc func loadAndInject(tmpfile: String, oldClass: AnyClass? = nil)
        throws -> [AnyClass] {
        _ = loadXCTest
        _ = loadTestsBundle

        print("\(APP_PREFIX)Loading .dylib ...")
        // load patched .dylib into process with new version of class
        var dl: UnsafeMutableRawPointer?
        for dylib in "\(tmpfile).dylib".components(separatedBy: Self.dylibDelim) {
            dl = dlopen(dylib, RTLD_NOW)
            guard dl != nil else {
                var error = String(cString: dlerror())
                if error.contains("___llvm_profile_runtime") {
                    error += """
                        \n\(APP_PREFIX)⚠️ Loading .dylib has failed, try turning off \
                        collection of test coverage in your scheme
                        """
                } else if error.contains("ymbol not found") {
                    error += """
                        \n\(APP_PREFIX)⚠️ Loading .dylib has failed, This is likely \
                        because Swift code being injected refers to a function \
                        with a default argument or perhaps an XCTest that depends on \
                        code not normally linked into your application. Rebuilding and \
                        re-running your project (without a build clean) can resolve this.
                        """
                    forceUnhide()
                }
                throw evalError("dlopen() error: \(error)")
            }
        }

        if oldClass != nil {
            // find patched version of class using symbol for existing

            var info = Dl_info()
            guard dladdr(unsafeBitCast(oldClass, to: UnsafeRawPointer.self), &info) != 0 else {
                throw evalError("Could not locate class symbol")
            }

            debug(String(cString: info.dli_sname))
            guard let newSymbol = dlsym(dl, info.dli_sname) else {
                throw evalError("Could not locate newly loaded class symbol")
            }

            return [unsafeBitCast(newSymbol, to: AnyClass.self)]
        }
        else {
            // grep out symbols for classes being injected from object file

            return try extractClasses(dl: dl!, tmpfile: tmpfile)
        }
    }

    func startUnhide() {
    }

    // Overridden by SwiftInjectionEval subclass for injection
    @objc func extractClasses(dl: UnsafeMutableRawPointer,
                              tmpfile: String) throws -> [AnyClass] {
        guard shell(command: """
            \(xcodeDev)/Toolchains/XcodeDefault.xctoolchain/usr/bin/nm \(tmpfile).o | \
            grep -E ' S _OBJC_CLASS_\\$_| _(_T0|\\$S|\\$s).*CN$' | awk '{print $3}' \
            >\(tmpfile).classes
            """) else {
            throw evalError("Could not list class symbols")
        }
        guard var classSymbolNames = (try? String(contentsOfFile:
            "\(tmpfile).classes"))?.components(separatedBy: "\n") else {
            throw evalError("Could not load class symbol list")
        }
        classSymbolNames.removeLast()
        return Set(classSymbolNames.compactMap {
            dlsym(dl, String($0.dropFirst())) })
            .map { unsafeBitCast($0, to: AnyClass.self) }
    }

    func findCompileCommand(logsDir: URL, classNameOrFile: String, tmpfile: String)
        throws -> (compileCommand: String, sourceFile: String)? {
        // path to project can contain spaces and '$&(){}
        // Objective-C paths can only contain space and '
        // project file itself can only contain spaces
        let isFile = classNameOrFile.hasPrefix("/")
        let sourceRegex = isFile ?
            #"\Q\#(classNameOrFile)\E"# : #"/\#(classNameOrFile)\.\w+"#
        let swiftEscaped = (isFile ? "" : #"[^"]*?"#) + sourceRegex.escaping("'$", with: #"\E\\*$0\Q"#)
        let objcEscaped = (isFile ? "" :
            #"(?:/(?:[^/\\]*\\.)*[^/\\ ]+)+"#) +
            sourceRegex.escaping("' {}()&*")
        var regexp = #" -(?:primary-file|c(?<!-frontend -c)) (?:\\?"(\#(swiftEscaped))\\?"|(\#(objcEscaped))) "#

//        print(regexp)
        let swiftpm = projectFile?.hasSuffix(".swiftpm") == true ?
            " and $line !~ / -module-name App /" : ""
        // messy but fast
        try #"""
                    use JSON::PP;
                    use English;
                    use strict;

                    # line separator in Xcode logs
                    $INPUT_RECORD_SEPARATOR = "\r";

                    # format is gzip
                    open GUNZIP, "/usr/bin/gunzip <\"$ARGV[0]\" 2>/dev/null |" or die "gnozip";

                    # grep the log until there is a match
                    my ($realPath, $command);
                    while (defined (my $line = <GUNZIP>)) {
                        if ($line =~ /^\s*cd /) {
                            $realPath = $line;
                        }
                        elsif ($line =~ m@\#(regexp.escaping("\"$")
                                    .escaping("@", with: #"\E\$0\Q"#)
                            )@oi and $line =~ " \#(arch)"\#(swiftpm)) {
                            # found compile command
                            # may need to extract file list
                            if ($line =~ / -filelist /) {
                                while (defined (my $line2 = <GUNZIP>)) {
                                    if (my($filemap) = $line2 =~ / -output-file-map ([^ \\]+(?:\\.[^ \\]+)*) / ) {
                                        $filemap =~ s/\\//g;
                                        my $file_handle = IO::File->new( "< $filemap" )
                                            or die "Could not open filemap '$filemap'";
                                        my $json_text = join'', $file_handle->getlines();
                                        my $json_map = decode_json( $json_text, { utf8  => 1 } );
                                        my $filelist = '\#(tmpDir)/filelist.txt';
                                        my $swift_sources = join "\n", keys %$json_map;
                                        my $listfile = IO::File->new( "> $filelist" )
                                            or die "Could not open list file '$filelist'";
                                        binmode $listfile, ':utf8';
                                        $listfile->print( $swift_sources );
                                        $listfile->close();
                                        $line =~ s/( -filelist )(\#(
                                            Self.argumentRegex))( )/$1$filelist$3/;
                                        last;
                                    }
                                }
                            }
                            if ($realPath and (undef, $realPath) = $realPath =~ /cd (\"?)(.*?)\1\r/) {
                    #           print "cd \"$realPath\" && ";
                            }
                            # find last
                            $command = $line
                            #exit 0;
                        }
                        elsif (my ($bazel, $dir) = $line =~ /^Running "([^"]+)".* (?:patching output for workspace root|with project path) at ("[^"]+")/) {
                            $command = "cd $dir && $bazel";
                            last;
                        }
                    }

                    if ($command) {
                        print $command;
                        exit 0;
                    }
                    # class/file not found
                    exit 1;
                    """#.write(toFile: "\(tmpfile).pl",
                               atomically: false, encoding: .utf8)

        guard shell(command: """
            # search through build logs, most recent first
            cd "\(logsDir.path.escaping("$"))" &&
            for log in `ls -t *.xcactivitylog`; do
                #echo "Scanning $log"
                /usr/bin/env perl "\(tmpfile).pl" "$log" \
                >"\(tmpfile).sh" 2>"\(tmpfile).err" && exit 0
            done
            exit 1;
            """) else {
            #if targetEnvironment(simulator)
            if #available(iOS 14.0, tvOS 14.0, *) {
            } else {
                print(APP_PREFIX+"""
                    ⚠️ Injection unable to search logs. \
                    Try a more recent iOS 14+ simulator \
                    or, download a release directly from \
                    https://github.com/johnno1962/InjectionIII/releases
                    """)
            }
            #endif
            if let log = try? String(contentsOfFile: "\(tmpfile).err"),
               log.contains("error") {
                throw evalError(log)
            }
            return nil
        }

        var compileCommand: String
        do {
            compileCommand = try String(contentsOfFile: "\(tmpfile).sh")
        } catch {
            throw evalError("""
                Error reading \(tmpfile).sh, scanCommand: \(cmdfile)
                """)
        }

//            // escape ( & ) outside quotes
//            .replacingOccurrences(of: "[()](?=(?:(?:[^\"]*\"){2})*[^\"]$)", with: "\\\\$0", options: [.regularExpression])
            // (logs of new build system escape ', $ and ")
        debug("Found command:", compileCommand)
        compileCommand = compileCommand
            .replacingOccurrences(of: #"builtin-swift(DriverJob|Task)Execution --"#,
                                  with: "", options: .regularExpression)
//            // remove excess escaping in new build system (no linger necessary)
//            .replacingOccurrences(of: #"\\([\"'\\])"#, with: "$1", options: [.regularExpression])
            // these files may no longer exist
            .replacingOccurrences(of:
                #" -(pch-output-dir|supplementary-output-file-map|index-store-path) \#(Self.argumentRegex) "#,
                                  with: " ", options: .regularExpression)
        debug("Replaced command:", compileCommand)

        if isFile {
            return (compileCommand, classNameOrFile)
        }

        // for eval() extract full path to file from compile command

        let fileExtractor: NSRegularExpression
        regexp = regexp.escaping("$")

        do {
            fileExtractor = try NSRegularExpression(pattern: regexp, options: [])
        }
        catch {
            throw evalError("Regexp parse error: \(error) -- \(regexp)")
        }

        guard let matches = fileExtractor
            .firstMatch(in: compileCommand, options: [],
                        range: NSMakeRange(0, compileCommand.utf16.count)),
            var sourceFile = compileCommand[matches.range(at: 1)] ??
                             compileCommand[matches.range(at: 2)] else {
            throw evalError("Could not locate source file \(compileCommand) -- \(regexp)")
        }

        sourceFile = actualCase(path: sourceFile.unescape()) ?? sourceFile
        return (compileCommand, sourceFile)
    }

    func getAppCodeDerivedData(procPath: String) -> String {
        //Default with current year
        let derivedDataPath = { (year: Int, pathSelector: String) -> String in
            "Library/Caches/\(year > 2019 ? "JetBrains/" : "")\(pathSelector)/DerivedData"
        }

        let year = Calendar.current.component(.year, from: Date())
        let month = Calendar.current.component(.month, from: Date())

        let defaultPath = derivedDataPath(year, "AppCode\(month / 4 == 0 ? year - 1 : year).\(month / 4 + (month / 4 == 0 ? 3 : 0))")

        var plistPath = URL(fileURLWithPath: procPath)
        plistPath.deleteLastPathComponent()
        plistPath.deleteLastPathComponent()
        plistPath = plistPath.appendingPathComponent("Info.plist")

        guard let dictionary = NSDictionary(contentsOf: plistPath) as? Dictionary<String, Any> else { return defaultPath }
        guard let jvmOptions = dictionary["JVMOptions"] as? Dictionary<String, Any> else { return defaultPath }
        guard let properties = jvmOptions["Properties"] as? Dictionary<String, Any> else { return defaultPath }
        guard let pathSelector: String = properties["idea.paths.selector"] as? String else { return defaultPath }

        let components = pathSelector.replacingOccurrences(of: "AppCode", with: "").components(separatedBy: ".")
        guard components.count == 2 else { return defaultPath }

        guard let realYear = Int(components[0]) else { return defaultPath }
        return derivedDataPath(realYear, pathSelector)
    }

    func findDerivedData(url: URL, ideProcPath: String) -> URL? {
        if url.path == "/" {
            return nil
        }

        var relativeDirs = ["DerivedData", "build/DerivedData"]
        if ideProcPath.lowercased().contains("appcode") {
            relativeDirs.append(getAppCodeDerivedData(procPath: ideProcPath))
        } else {
            relativeDirs.append("Library/Developer/Xcode/DerivedData")
        }
        for relative in relativeDirs {
            let derived = url.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: derived.path) {
                return derived
            }
        }

        return findDerivedData(url: url.deletingLastPathComponent(), ideProcPath: ideProcPath)
    }

    func findProject(for source: URL, derivedData: URL) -> (projectFile: URL, logsDir: URL)? {
        let dir = source.deletingLastPathComponent()
        if dir.path == "/" {
            return nil
        }

        if bazelLight {
            let workspaceURL = dir.deletingLastPathComponent()
                .appendingPathComponent(bazelWorkspace)
            if FileManager.default.fileExists(atPath: workspaceURL.path) {
                return (workspaceURL, derivedLogs.flatMap({
                    URL(fileURLWithPath: $0)}) ?? dir)
            }
        }

        var candidate = findProject(for: dir, derivedData: derivedData)
        if let files =
                try? FileManager.default.contentsOfDirectory(atPath: dir.path),
            let project = file(withExt: ".xcworkspace", in: files) ??
                            file(withExt: ".xcodeproj", in: files),
            let logsDir = logsDir(project: dir.appendingPathComponent(project), derivedData: derivedData),
            mtime(logsDir) > candidate.flatMap({ mtime($0.logsDir) }) ?? 0 {
                candidate = (dir.appendingPathComponent(project), logsDir)
        }

        return candidate
    }

    func file(withExt ext: String, in files: [String]) -> String? {
        return files.first { $0.hasSuffix(ext) }
    }

    func mtime(_ url: URL) -> time_t {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_mtimespec.tv_sec : 0
    }

    func logsDir(project: URL, derivedData: URL) -> URL? {
        let filemgr = FileManager.default
        let projectPrefix = project.deletingPathExtension()
            .lastPathComponent.replacingOccurrences(of: #"\s+"#, with: "_",
                                    options: .regularExpression, range: nil)
        var possibleDerivedData = (try? filemgr
            .contentsOfDirectory(atPath: derivedData.path))?
            .filter { $0.starts(with: projectPrefix + "-") }
            .map { derivedData.appendingPathComponent($0 + "/Logs/Build") } ?? []
        possibleDerivedData.append(project.deletingLastPathComponent()
            .appendingPathComponent("DerivedData/\(projectPrefix)/Logs/Build"))
        debug("Possible DerivedDatas: \(possibleDerivedData)")

        // use most recentry modified
        return possibleDerivedData
            .filter { filemgr.fileExists(atPath: $0.path) }
            .sorted { mtime($0) > mtime($1) }
            .first
    }

    class func uniqueTypeNames(signatures: [String], exec: (String) -> Void) {
        var typesSearched = Set<String>()

        for signature in signatures {
            let parts = signature.components(separatedBy: ".")
            if parts.count < 3 {
                continue
            }
            let typeName = parts[1]
            if typesSearched.insert(typeName).inserted {
                exec(typeName)
            }
        }
    }

    func shell(command: String) -> Bool {
        try! command.write(toFile: cmdfile, atomically: false, encoding: .utf8)
        debug(command)

        #if os(macOS)
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [cmdfile]
        task.launch()
        task.waitUntilExit()
        let status = task.terminationStatus
        #else
        let status = runner.run(script: cmdfile)
        #endif
        return status == EXIT_SUCCESS
    }

    #if !os(macOS)
    lazy var runner = ScriptRunner()

    class ScriptRunner {
        let commandsOut: UnsafeMutablePointer<FILE>
        let statusesIn: UnsafeMutablePointer<FILE>

        init() {
            let ForReading = 0, ForWriting = 1
            var commandsPipe = [Int32](repeating: 0, count: 2)
            var statusesPipe = [Int32](repeating: 0, count: 2)
            pipe(&commandsPipe)
            pipe(&statusesPipe)

            var envp = [UnsafeMutablePointer<CChar>?](repeating: nil, count: 2)
            if let home = getenv("USER_HOME") {
                envp[0] = strdup("HOME=\(home)")!
            }

            if fork() == 0 {
                let commandsIn = fdopen(commandsPipe[ForReading], "r")
                let statusesOut = fdopen(statusesPipe[ForWriting], "w")
                var buffer = [Int8](repeating: 0, count: Int(MAXPATHLEN))

                close(commandsPipe[ForWriting])
                close(statusesPipe[ForReading])
                setbuf(statusesOut, nil)

                while let script = fgets(&buffer, Int32(buffer.count), commandsIn) {
                    script[strlen(script)-1] = 0

                    let pid = fork()
                    if pid == 0 {
                        var argv = [UnsafeMutablePointer<Int8>?](repeating: nil, count: 3)
                        argv[0] = strdup("/bin/bash")!
                        argv[1] = strdup(script)!
                        _ = execve(argv[0], &argv, &envp)
                        fatalError("execve() fails \(String(cString: strerror(errno)))")
                    }

                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1 {}
                    fputs("\(status)\n", statusesOut)
                }

                exit(0)
            }

            commandsOut = fdopen(commandsPipe[ForWriting], "w")
            statusesIn = fdopen(statusesPipe[ForReading], "r")

            close(commandsPipe[ForReading])
            close(statusesPipe[ForWriting])
            setbuf(commandsOut, nil)
        }

        func run(script: String) -> Int32 {
            fputs("\(script)\n", commandsOut)
            var buffer = [Int8](repeating: 0, count: 20)
            fgets(&buffer, Int32(buffer.count), statusesIn)
            let status = atoi(buffer)
            return status >> 8 | status & 0xff
        }
    }
    #endif

    #if DEBUG && !SWIFT_PACKAGE
    deinit {
        NSLog("\(self).deinit()")
    }
    #endif
}

@_silgen_name("fork")
func fork() -> Int32
@_silgen_name("execve")
func execve(_ __file: UnsafePointer<Int8>!,
            _ __argv: UnsafePointer<UnsafeMutablePointer<Int8>?>!,
            _ __envp: UnsafePointer<UnsafeMutablePointer<Int8>?>!) -> Int32
#endif

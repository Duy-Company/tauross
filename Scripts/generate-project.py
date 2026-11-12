#!/usr/bin/env python3
"""Generate the Xcode project and pinned Sparkle integration using stable IDs."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = []
def obj(name, body):
    objects.append(f'\t\t{ident(name)} = {{ {body} }};')
    return ident(name)
sources = sorted((root / 'Tauross').rglob('*.swift'))
source_refs, build_refs = [], []
for source in sources:
    path = source.relative_to(root).as_posix()
    source_refs.append(obj(path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = SOURCE_ROOT;'))
    build_refs.append(obj('build:' + path, f'isa = PBXBuildFile; fileRef = {ident(path)};'))
obj('resources', 'isa = PBXFileReference; lastKnownFileType = folder; path = Tauross/Resources; sourceTree = SOURCE_ROOT;')
obj('resources-build', f'isa = PBXBuildFile; fileRef = {ident("resources")};')
obj('plist', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Config/Info.plist; sourceTree = SOURCE_ROOT;')
obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Tauross.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products', f'isa = PBXGroup; children = ({ident("product")}); name = Products; sourceTree = "<group>";')
obj('group', f'isa = PBXGroup; children = ({",".join(source_refs + [ident("resources"), ident("plist"), ident("products")])}); sourceTree = "<group>";')
obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(build_refs)}); runOnlyForDeploymentPostprocessing = 0;')
obj('resource-phase', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ident("resources-build")}); runOnlyForDeploymentPostprocessing = 0;')
obj('sparkle-package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sparkle-project/Sparkle"; requirement = { kind = exactVersion; version = 2.10.1; };')
obj('sparkle-product', f'isa = XCSwiftPackageProductDependency; package = {ident("sparkle-package")}; productName = Sparkle;')
obj('sparkle-link', f'isa = PBXBuildFile; productRef = {ident("sparkle-product")};')
obj('framework-phase', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({ident("sparkle-link")}); runOnlyForDeploymentPostprocessing = 0;')
for mode in ['Debug', 'Release']:
    obj('project-' + mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0; CLANG_ENABLE_MODULES = YES; }};')
    optimization = '-Onone' if mode == 'Debug' else '-O'
    obj('target-' + mode, f'''isa = XCBuildConfiguration; name = {mode}; buildSettings = {{
        PRODUCT_NAME = Tauross; PRODUCT_BUNDLE_IDENTIFIER = com.tauross.mac;
        INFOPLIST_FILE = Config/Info.plist; GENERATE_INFOPLIST_FILE = NO;
        SWIFT_VERSION = 5.0; SWIFT_OPTIMIZATION_LEVEL = {quote(optimization)};
        DEBUG_INFORMATION_FORMAT = {quote('dwarf' if mode == 'Debug' else 'dwarf-with-dsym')};
        SWIFT_ACTIVE_COMPILATION_CONDITIONS = {quote('DEBUG' if mode == 'Debug' else '')};
        CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual;
        ENABLE_APP_SANDBOX = NO;
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
        COMBINE_HIDPI_IMAGES = YES;
    }};''')
for scope in ['project', 'target']:
    obj(scope + '-configs', f'isa = XCConfigurationList; buildConfigurations = ({ident(scope + "-Debug")},{ident(scope + "-Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target', f'''isa = PBXNativeTarget; name = Tauross; productName = Tauross;
    productType = "com.apple.product-type.application"; productReference = {ident("product")};
    buildConfigurationList = {ident("target-configs")};
    buildPhases = ({ident("sources")},{ident("framework-phase")},{ident("resource-phase")});
    packageProductDependencies = ({ident("sparkle-product")});
    buildRules = (); dependencies = ();''')
obj('project', f'''isa = PBXProject; attributes = {{ LastUpgradeCheck = 2630; }};
    buildConfigurationList = {ident("project-configs")}; compatibilityVersion = "Xcode 14.0";
    developmentRegion = en; knownRegions = (en,Base); mainGroup = {ident("group")};
    productRefGroup = {ident("products")}; packageReferences = ({ident("sparkle-package")});
    projectDirPath = ""; projectRoot = ""; targets = ({ident("target")});''')
project = root / 'Tauross.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {ident("project")};\n}}\n')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'Tauross.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="Tauross.app" BlueprintName="Tauross" ReferencedContainer="container:Tauross.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="Tauross.app" BlueprintName="Tauross" ReferencedContainer="container:Tauross.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="Tauross.app" BlueprintName="Tauross" ReferencedContainer="container:Tauross.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated Tauross.xcodeproj')

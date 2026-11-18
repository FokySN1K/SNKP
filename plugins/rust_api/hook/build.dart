import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under
// lib. The libclang driver has no install directory, so clang's builtin
// headers (stdbool.h and friends) are only reachable through an explicit
// resource dir.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets ||
      input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final triple = _androidTriple(input.config.code.targetArchitecture);
  final llvmRoot = File.fromUri(compiler).parent.parent;
  final separator = Platform.pathSeparator;
  final sysroot = '${llvmRoot.path}${separator}sysroot';
  final includeDir =
      '$sysroot${separator}usr${separator}include${separator}$triple';
  return {
    'LIBCLANG_PATH': _libclangDirectory(llvmRoot),
    // bindgen checks the dash-spelled triple first while the Rust builder only
    // fills the underscore one, so this value is never clobbered.
    'BINDGEN_EXTRA_CLANG_ARGS_$triple': '--sysroot=$sysroot '
        '-resource-dir=${_clangResourceDirectory(llvmRoot)} '
        '-I$includeDir',
  };
}

String _androidTriple(Architecture architecture) {
  return switch (architecture) {
    Architecture.arm64 => 'aarch64-linux-android',
    Architecture.arm => 'armv7-linux-androideabi',
    Architecture.x64 => 'x86_64-linux-android',
    _ => throw StateError('bindgen cannot target $architecture on Android'),
  };
}

String _libclangDirectory(Directory llvmRoot) {
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return directory.path;
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

String _clangResourceDirectory(Directory llvmRoot) {
  final separator = Platform.pathSeparator;
  final clangDirectory = Directory(
    '${llvmRoot.path}${separator}lib${separator}clang',
  );
  if (clangDirectory.existsSync()) {
    for (final entity in clangDirectory.listSync()) {
      if (entity is! Directory) {
        continue;
      }
      final stdbool = File(
        '${entity.path}${separator}include${separator}stdbool.h',
      );
      if (stdbool.existsSync()) {
        return entity.path;
      }
    }
  }
  throw StateError(
    'No clang resource dir under ${clangDirectory.path}; the NDK Flutter '
    'passed cannot compile bindgen translations for rquickjs',
  );
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}

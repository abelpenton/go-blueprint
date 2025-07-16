#!/bin/bash

set -euo pipefail

VERSION="$1"
PACKAGE_NAME="go-blueprint-beta-npm"
MAIN_PACKAGE_DIR="npm-package"
PLATFORM_PACKAGES_DIR="platform-packages"

rm -rf "$MAIN_PACKAGE_DIR" "$PLATFORM_PACKAGES_DIR"

mkdir -p "$MAIN_PACKAGE_DIR/bin" "$PLATFORM_PACKAGES_DIR"

declare -A PLATFORM_MAP=(
    ["go-blueprint_${VERSION}_Darwin_all"]="darwin-x64,darwin-arm64"
    ["go-blueprint_${VERSION}_Linux_x86_64"]="linux-x64"
    ["go-blueprint_${VERSION}_Linux_arm64"]="linux-arm64"
    ["go-blueprint_${VERSION}_Windows_x86_64"]="win32-x64"
    ["go-blueprint_${VERSION}_Windows_arm64"]="win32-arm64"
)

declare -A OS_MAP=(
    ["darwin-x64"]="darwin"
    ["darwin-arm64"]="darwin"
    ["linux-x64"]="linux"
    ["linux-arm64"]="linux"
    ["win32-x64"]="win32"
    ["win32-arm64"]="win32"
)

declare -A CPU_MAP=(
    ["darwin-x64"]="x64"
    ["darwin-arm64"]="arm64"
    ["linux-x64"]="x64"
    ["linux-arm64"]="arm64"
    ["win32-x64"]="x64"
    ["win32-arm64"]="arm64"
)

PLATFORM_CONFIG="{"
FIRST_ENTRY=true
for platform_key in "${!OS_MAP[@]}"; do
    if [ "$FIRST_ENTRY" = true ]; then
        FIRST_ENTRY=false
    else
        PLATFORM_CONFIG="$PLATFORM_CONFIG,"
    fi
    PLATFORM_CONFIG="$PLATFORM_CONFIG'$platform_key': '$PACKAGE_NAME-$platform_key'"
done
PLATFORM_CONFIG="$PLATFORM_CONFIG}"

OPTIONAL_DEPS=""
for archive in dist/*.tar.gz dist/*.zip; do
    if [ -f "$archive" ]; then
        archive_name=$(basename "$archive")
        archive_name="${archive_name%.tar.gz}"
        archive_name="${archive_name%.zip}"
        
        platform_keys="${PLATFORM_MAP[$archive_name]:-}"
        
        if [ -n "$platform_keys" ]; then
            echo "Processing $archive for platforms: $platform_keys"
            
            IFS=',' read -ra PLATFORM_ARRAY <<< "$platform_keys"
            for platform_key in "${PLATFORM_ARRAY[@]}"; do
                platform_key=$(echo "$platform_key" | xargs)
                
                echo "  Creating package for platform: $platform_key"
                
                platform_package_dir="$PLATFORM_PACKAGES_DIR/$PACKAGE_NAME-$platform_key"
                mkdir -p "$platform_package_dir/bin"
                
                if [[ "$archive" == *.tar.gz ]]; then
                    tar -xzf "$archive" -C "$platform_package_dir/bin"
                else
                    unzip -j "$archive" -d "$platform_package_dir/bin"
                fi
                
                for doc_file in README.md README README.txt LICENSE LICENSE.md LICENSE.txt; do
                    if [ -f "$platform_package_dir/bin/$doc_file" ]; then
                        mv "$platform_package_dir/bin/$doc_file" "$platform_package_dir/"
                    fi
                done
                
                ls -l "$platform_package_dir/bin"
                chmod +x "$platform_package_dir/bin/"*
                
                os_value="${OS_MAP[$platform_key]}"
                cpu_value="${CPU_MAP[$platform_key]}"
                
                if [[ "$platform_key" == win32-* ]]; then
                    binary_name="go-blueprint.exe"
                else
                    binary_name="go-blueprint"
                fi
                
                files_array='["bin/"]'
                for doc_file in README.md README README.txt LICENSE LICENSE.md LICENSE.txt; do
                    if [ -f "$platform_package_dir/$doc_file" ]; then
                        files_array="${files_array%]}, \"$doc_file\"]"
                    fi
                done
                
                cat > "$platform_package_dir/package.json" << EOF
{
  "name": "$PACKAGE_NAME-$platform_key",
  "version": "$VERSION",
  "description": "Platform-specific binary for $PACKAGE_NAME ($platform_key)",
  "main": "bin/$binary_name",
  "bin": {
    "go-blueprint": "bin/$binary_name"
  },
  "os": ["$os_value"],
  "cpu": ["$cpu_value"],
  "files": $files_array,
  "repository": {
    "type": "git",
    "url": "https://github.com/abelpenton/go-blueprint.git"
  },
  "author": "Abel Penton",
  "license": "MIT"
}
EOF
                
                if [ -n "$OPTIONAL_DEPS" ]; then
                    OPTIONAL_DEPS="$OPTIONAL_DEPS,"
                fi
                OPTIONAL_DEPS="$OPTIONAL_DEPS\"$PACKAGE_NAME-$platform_key\": \"$VERSION\""
            done
        fi
    fi
done

cat > "$MAIN_PACKAGE_DIR/bin/go-blueprint" << 'EOF'
#!/usr/bin/env node

const { execFileSync } = require('child_process')
const path = require('path')

function findAndExecuteBinary() {
  const args = process.argv.slice(2)
  
  const platformKey = `${process.platform}-${process.arch}`
  const platformPackageName = `go-blueprint-beta-npm-${platformKey}`

  try {
    const platformPackage = require(platformPackageName)
    const binaryPath = require.resolve(`${platformPackageName}/bin/go-blueprint${process.platform === 'win32' ? '.exe' : ''}`)
    execFileSync(binaryPath, args, { stdio: 'inherit' })
    return
  } catch (error) {
  }
  
  const binaryName = process.platform === 'win32' ? 'go-blueprint.exe' : 'go-blueprint'
  const localBinaryPath = path.join(__dirname, binaryName)
  
  try {
    execFileSync(localBinaryPath, args, { stdio: 'inherit' })
  } catch (error) {
    console.error(`Failed to execute go-blueprint: ${error.message}`)
    process.exit(1)
  }
}

findAndExecuteBinary()
EOF

chmod +x "$MAIN_PACKAGE_DIR/bin/go-blueprint"

cat > "$MAIN_PACKAGE_DIR/package.json" << EOF
{
  "name": "$PACKAGE_NAME",
  "version": "$VERSION",
  "description": "A CLI for scaffolding Go projects with modern tooling",
  "main": "index.js",
  "bin": {
    "go-blueprint": "bin/go-blueprint"
  },
  "optionalDependencies": {
    $OPTIONAL_DEPS
  },
  "keywords": ["go", "golang", "cli"],
  "author": "Abel Penton",
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "https://github.com/abelpenton/go-blueprint.git"
  },
  "homepage": "https://github.com/abelpenton/go-blueprint",
  "engines": {
    "node": ">=14.0.0"
  },
  "files": [
    "bin/",
    "index.js"
  ]
}
EOF

cat > "$MAIN_PACKAGE_DIR/index.js" << 'EOF'
const { execFileSync } = require('child_process')
const path = require('path')

function getBinaryPath() {
  const platformKey = `${process.platform}-${process.arch}`
  const platformPackageName = `go-blueprint-beta-npm-${platformKey}`
  const binaryName = process.platform === 'win32' ? 'go-blueprint.exe' : 'go-blueprint'
  
  try {
    return require.resolve(`${platformPackageName}/bin/${binaryName}`)
  } catch (error) {
    return path.join(__dirname, 'bin', binaryName)
  }
}

module.exports = {
  getBinaryPath,
  run: function(...args) {
    const binaryPath = getBinaryPath()
    return execFileSync(binaryPath, args, { stdio: 'inherit' })
  }
}
EOF
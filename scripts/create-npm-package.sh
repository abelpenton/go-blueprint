#!/bin/bash

set -euo pipefail

VERSION="$1"
PACKAGE_NAME="go-blueprint"
MAIN_PACKAGE_DIR="npm-package"
PLATFORM_PACKAGES_DIR="platform-packages"

rm -rf "$MAIN_PACKAGE_DIR" "$PLATFORM_PACKAGES_DIR"

mkdir -p "$MAIN_PACKAGE_DIR/bin" "$PLATFORM_PACKAGES_DIR"

declare -A PLATFORM_MAP=(
    ["go-blueprint_${VERSION}_Darwin_x86_64"]="darwin-x64"
    ["go-blueprint_${VERSION}_Darwin_arm64"]="darwin-arm64"
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

OPTIONAL_DEPS=""
for archive in dist/*.tar.gz dist/*.zip; do
    if [ -f "$archive" ]; then
        archive_name=$(basename "$archive")
        archive_name="${archive_name%.tar.gz}"
        archive_name="${archive_name%.zip}"
        
        platform_key="${PLATFORM_MAP[$archive_name]:-}"
        
        if [ -n "$platform_key" ]; then
            echo "Processing $archive for platform $platform_key"
            
            platform_package_dir="$PLATFORM_PACKAGES_DIR/$PACKAGE_NAME-$platform_key"
            mkdir -p "$platform_package_dir/bin"
            
            if [[ "$archive" == *.tar.gz ]]; then
                tar -xzf "$archive" -C "$platform_package_dir/bin" --strip-components=1
            else
                unzip -j "$archive" -d "$platform_package_dir/bin"
            fi
            
            chmod +x "$platform_package_dir/bin/"*
            
            os_value="${OS_MAP[$platform_key]}"
            cpu_value="${CPU_MAP[$platform_key]}"
            
            cat > "$platform_package_dir/package.json" << EOF
{
  "name": "$PACKAGE_NAME-$platform_key",
  "version": "$VERSION",
  "description": "Platform-specific binary for $PACKAGE_NAME ($platform_key)",
  "os": ["$os_value"],
  "cpu": ["$cpu_value"],
  "files": ["bin/"],
  "repository": {
    "type": "git",
    "url": "https://github.com/melkeydev/go-blueprint.git"
  },
  "author": "Melkey",
  "license": "MIT"
}
EOF
            
            if [ -n "$OPTIONAL_DEPS" ]; then
                OPTIONAL_DEPS="$OPTIONAL_DEPS,"
            fi
            OPTIONAL_DEPS="$OPTIONAL_DEPS\"$PACKAGE_NAME-$platform_key\": \"$VERSION\""
        fi
    fi
done

cat > "$MAIN_PACKAGE_DIR/install.js" << 'EOF'
const fs = require('fs')
const path = require('path')
const zlib = require('zlib')
const https = require('https')

// Lookup table for all platforms and binary distribution packages
const BINARY_DISTRIBUTION_PACKAGES = {
  'darwin-x64': 'go-blueprint-darwin-x64',
  'darwin-arm64': 'go-blueprint-darwin-arm64',
  'linux-x64': 'go-blueprint-linux-x64',
  'linux-arm64': 'go-blueprint-linux-arm64',
  'win32-x64': 'go-blueprint-win32-x64',
  'win32-arm64': 'go-blueprint-win32-arm64',
}

// Get version from package.json
const packageJson = require('./package.json')
const BINARY_DISTRIBUTION_VERSION = packageJson.version

// Windows binaries end with .exe
const binaryName = process.platform === 'win32' ? 'go-blueprint.exe' : 'go-blueprint'

// Determine package name for this platform
const platformSpecificPackageName = BINARY_DISTRIBUTION_PACKAGES[`${process.platform}-${process.arch}`]

// Compute the path we want to emit the fallback binary to
const fallbackBinaryPath = path.join(__dirname, binaryName)

function makeRequest(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, (response) => {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          const chunks = []
          response.on('data', (chunk) => chunks.push(chunk))
          response.on('end', () => {
            resolve(Buffer.concat(chunks))
          })
        } else if (
          response.statusCode >= 300 &&
          response.statusCode < 400 &&
          response.headers.location
        ) {
          // Follow redirects
          makeRequest(response.headers.location).then(resolve, reject)
        } else {
          reject(
            new Error(
              `npm responded with status code ${response.statusCode} when downloading the package!`
            )
          )
        }
      })
      .on('error', (error) => {
        reject(error)
      })
  })
}

function extractFileFromTarball(tarballBuffer, filepath) {
  // Tar archives are organized in 512 byte blocks
  let offset = 0
  while (offset < tarballBuffer.length) {
    const header = tarballBuffer.subarray(offset, offset + 512)
    offset += 512
    const fileName = header.toString('utf-8', 0, 100).replace(/\0.*/g, '')
    const fileSize = parseInt(header.toString('utf-8', 124, 136).replace(/\0.*/g, ''), 8)
    
    if (fileName === filepath) {
      return tarballBuffer.subarray(offset, offset + fileSize)
    }
    
    // Clamp offset to the upper multiple of 512
    offset = (offset + fileSize + 511) & ~511
  }
}

async function downloadBinaryFromNpm() {
  try {
    console.log('Downloading binary from npm registry...')
    
    // Download the tarball of the right binary distribution package
    const tarballDownloadBuffer = await makeRequest(
      `https://registry.npmjs.org/${platformSpecificPackageName}/-/${platformSpecificPackageName}-${BINARY_DISTRIBUTION_VERSION}.tgz`
    )
    const tarballBuffer = zlib.gunzipSync(tarballDownloadBuffer)
    
    // Extract binary from package and write to disk
    const binaryData = extractFileFromTarball(tarballBuffer, `package/bin/${binaryName}`)
    
    if (!binaryData) {
      throw new Error(`Binary ${binaryName} not found in package`)
    }
    
    fs.writeFileSync(fallbackBinaryPath, binaryData, { mode: 0o755 })
    console.log(`Binary downloaded and installed to ${fallbackBinaryPath}`)
  } catch (error) {
    console.error('Failed to download binary:', error.message)
    process.exit(1)
  }
}

function isPlatformSpecificPackageInstalled() {
  try {
    // Resolving will fail if the optionalDependency was not installed
    require.resolve(`${platformSpecificPackageName}/bin/${binaryName}`)
    return true
  } catch (e) {
    return false
  }
}

if (!platformSpecificPackageName) {
  console.error(`Platform ${process.platform}-${process.arch} is not supported!`)
  process.exit(1)
}

// Skip downloading the binary if it was already installed via optionalDependencies
if (!isPlatformSpecificPackageInstalled()) {
  console.log('Platform specific package not found. Will manually download binary.')
  downloadBinaryFromNpm()
} else {
  console.log('Platform specific package already installed.')
}
EOF

# Create the binary wrapper for CLI usage
cat > "$MAIN_PACKAGE_DIR/bin/go-blueprint" << 'EOF'
#!/usr/bin/env node

const path = require('path')
const { execFileSync } = require('child_process')

function getBinaryPath() {
  // Lookup table for all platforms and binary distribution packages
  const BINARY_DISTRIBUTION_PACKAGES = {
    'darwin-x64': 'go-blueprint-darwin-x64',
    'darwin-arm64': 'go-blueprint-darwin-arm64',
    'linux-x64': 'go-blueprint-linux-x64',
    'linux-arm64': 'go-blueprint-linux-arm64',
    'win32-x64': 'go-blueprint-win32-x64',
    'win32-arm64': 'go-blueprint-win32-arm64',
  }

  // Windows binaries end with .exe
  const binaryName = process.platform === 'win32' ? 'go-blueprint.exe' : 'go-blueprint'

  // Determine package name for this platform
  const platformSpecificPackageName = BINARY_DISTRIBUTION_PACKAGES[`${process.platform}-${process.arch}`]

  try {
    // Try to resolve from optionalDependency first
    return require.resolve(`${platformSpecificPackageName}/bin/${binaryName}`)
  } catch (e) {
    // Fall back to manually downloaded binary
    return path.join(__dirname, '..', binaryName)
  }
}

try {
  const binaryPath = getBinaryPath()
  execFileSync(binaryPath, process.argv.slice(2), { stdio: 'inherit' })
} catch (error) {
  console.error('Failed to execute go-blueprint:', error.message)
  process.exit(1)
}
EOF

# Make the CLI wrapper executable
chmod +x "$MAIN_PACKAGE_DIR/bin/go-blueprint"

# Create the main package.json
cat > "$MAIN_PACKAGE_DIR/package.json" << EOF
{
  "name": "go-blueprint",
  "version": "$VERSION",
  "description": "A CLI for scaffolding Go projects with modern tooling",
  "main": "index.js",
  "bin": {
    "go-blueprint": "bin/go-blueprint"
  },
  "scripts": {
    "postinstall": "node install.js"
  },
  "optionalDependencies": {
    $OPTIONAL_DEPS
  },
  "keywords": ["go", "golang", "cli", "scaffold", "template"],
  "author": "Melkey",
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "https://github.com/melkeydev/go-blueprint.git"
  },
  "homepage": "https://github.com/melkeydev/go-blueprint",
  "engines": {
    "node": ">=14.0.0"
  },
  "files": [
    "bin/",
    "install.js",
    "index.js"
  ]
}
EOF

cat > "$MAIN_PACKAGE_DIR/index.js" << 'EOF'
const path = require('path')
const { execFileSync } = require('child_process')

function getBinaryPath() {
  const BINARY_DISTRIBUTION_PACKAGES = {
    'darwin-x64': 'go-blueprint-darwin-x64',
    'darwin-arm64': 'go-blueprint-darwin-arm64',
    'linux-x64': 'go-blueprint-linux-x64',
    'linux-arm64': 'go-blueprint-linux-arm64',
    'win32-x64': 'go-blueprint-win32-x64',
    'win32-arm64': 'go-blueprint-win32-arm64',
  }

  const binaryName = process.platform === 'win32' ? 'go-blueprint.exe' : 'go-blueprint'
  const platformSpecificPackageName = BINARY_DISTRIBUTION_PACKAGES[`${process.platform}-${process.arch}`]

  try {
    return require.resolve(`${platformSpecificPackageName}/bin/${binaryName}`)
  } catch (e) {
    return path.join(__dirname, binaryName)
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

echo "✅ Created main package at $MAIN_PACKAGE_DIR"
echo "✅ Created platform-specific packages at $PLATFORM_PACKAGES_DIR"
echo ""
echo "Next steps:"
echo "1. Publish platform-specific packages first"
echo "2. Then publish the main package"
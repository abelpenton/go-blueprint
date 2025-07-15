#!/bin/bash

set -euo pipefail

VERSION="$1"
PACKAGE_NAME="go-blueprint-beta-npm"
MAIN_PACKAGE_DIR="npm-package"
PLATFORM_PACKAGES_DIR="platform-packages"

rm -rf "$MAIN_PACKAGE_DIR" "$PLATFORM_PACKAGES_DIR"

mkdir -p "$MAIN_PACKAGE_DIR/bin" "$PLATFORM_PACKAGES_DIR"

declare -A PLATFORM_MAP=(
    ["go-blueprint_${VERSION}_Darwin_x86_64"]="darwin-x64"
    ["go-blueprint_${VERSION}_Darwin_arm64"]="darwin-arm64"
    ["go-blueprint_${VERSION}_Linux_x86_64"]="linux-x64"
    ["go-blueprint_${VERSION}_Linux_arm64"]="linux-arm64"
    #["go-blueprint_${VERSION}_Windows_x86_64"]="win32-x64"
    ["go-blueprint_${VERSION}_Windows_arm64"]="win32-arm64"
)

declare -A OS_MAP=(
    ["darwin-x64"]="darwin"
    ["darwin-arm64"]="darwin"
    ["linux-x64"]="linux"
    ["linux-arm64"]="linux"
    #["win32-x64"]="win32"
    ["win32-arm64"]="win32"
)

declare -A CPU_MAP=(
    ["darwin-x64"]="x64"
    ["darwin-arm64"]="arm64"
    ["linux-x64"]="x64"
    ["linux-arm64"]="arm64"
    #["win32-x64"]="x64"
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
        
        platform_key="${PLATFORM_MAP[$archive_name]:-}"
        
        if [ -n "$platform_key" ]; then
            echo "Processing $archive for platform $platform_key"
            
            platform_package_dir="$PLATFORM_PACKAGES_DIR/$PACKAGE_NAME-$platform_key"
            mkdir -p "$platform_package_dir/bin"
            
            if [[ "$archive" == *.tar.gz ]]; then
                tar -xzf "$archive" -C "$platform_package_dir/bin"
            else
                unzip -j "$archive" -d "$platform_package_dir/bin"
            fi
            
            ls -l "$platform_package_dir/bin"
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
        fi
    fi
done

cat > "$MAIN_PACKAGE_DIR/constants.js" << EOF
const BINARY_DISTRIBUTION_PACKAGES = $PLATFORM_CONFIG

const BINARY_DISTRIBUTION_VERSION = require('./package.json').version

function getBinaryName() {
  if (process.platform === 'win32') {
    return 'go-blueprint.exe'
  }
  
  return 'go-blueprint'
}

function getPlatformPackageName() {
  return BINARY_DISTRIBUTION_PACKAGES[\`\${process.platform}-\${process.arch}\`]
}

function getAllBinaryNames() {
  if (process.platform === 'win32') {
    return ['go-blueprint.exe']
  }
  return ['go-blueprint']
}

module.exports = {
  BINARY_DISTRIBUTION_PACKAGES,
  BINARY_DISTRIBUTION_VERSION,
  getBinaryName,
  getPlatformPackageName,
  getAllBinaryNames
}
EOF

cat > "$MAIN_PACKAGE_DIR/utils.js" << 'EOF'
const path = require('path')
const fs = require('fs')
const { getBinaryName, getPlatformPackageName, getAllBinaryNames } = require('./constants')

function getBinaryPath() {
  const binaryName = getBinaryName()
  const platformSpecificPackageName = getPlatformPackageName()

  try {
    const resolvedPath = require.resolve(`${platformSpecificPackageName}/bin/${binaryName}`)
    if (fs.existsSync(resolvedPath)) {
      return resolvedPath
    }
  } catch (e) {
  }

  if (process.platform !== 'win32') {
    const allBinaryNames = getAllBinaryNames()
    for (const binName of allBinaryNames) {
      try {
        const resolvedPath = require.resolve(`${platformSpecificPackageName}/bin/${binName}`)
        if (fs.existsSync(resolvedPath)) {
          return resolvedPath
        }
      } catch (e) {
      }
    }
  }

  const localPath = path.join(__dirname, binaryName)
  if (fs.existsSync(localPath)) {
    return localPath
  }

  if (process.platform !== 'win32') {
    const allBinaryNames = getAllBinaryNames()
    for (const binName of allBinaryNames) {
      const fallbackPath = path.join(__dirname, binName)
      if (fs.existsSync(fallbackPath)) {
        return fallbackPath
      }
    }
  }

  return path.join(__dirname, binaryName)
}

function isPlatformSpecificPackageInstalled() {
  const platformSpecificPackageName = getPlatformPackageName()
  
  const allBinaryNames = getAllBinaryNames()
  for (const binName of allBinaryNames) {
    try {
      require.resolve(`${platformSpecificPackageName}/bin/${binName}`)
      return true
    } catch (e) {
    }
  }
  
  return false
}

module.exports = {
  getBinaryPath,
  isPlatformSpecificPackageInstalled
}
EOF

cat > "$MAIN_PACKAGE_DIR/install.js" << 'EOF'
const fs = require('fs')
const path = require('path')
const zlib = require('zlib')
const https = require('https')
const { BINARY_DISTRIBUTION_VERSION, getAllBinaryNames, getPlatformPackageName } = require('./constants')
const { isPlatformSpecificPackageInstalled } = require('./utils')

const platformSpecificPackageName = getPlatformPackageName()
const allBinaryNames = getAllBinaryNames()

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
  let offset = 0
  while (offset < tarballBuffer.length) {
    const header = tarballBuffer.subarray(offset, offset + 512)
    offset += 512
    const fileName = header.toString('utf-8', 0, 100).replace(/\0.*/g, '')
    const fileSize = parseInt(header.toString('utf-8', 124, 136).replace(/\0.*/g, ''), 8)
    
    if (fileName === filepath) {
      return tarballBuffer.subarray(offset, offset + fileSize)
    }
    
    offset = (offset + fileSize + 511) & ~511
  }
}

async function downloadBinaryFromNpm() {
  try {
    console.log('Downloading binary from npm registry...')
    const npmRegistryUrl = `https://registry.npmjs.org/${platformSpecificPackageName}/-/${platformSpecificPackageName}-${BINARY_DISTRIBUTION_VERSION}.tgz`
    console.log(`Fetching tarball from ${npmRegistryUrl}`)
    const tarballDownloadBuffer = await makeRequest(
      npmRegistryUrl
    )
    const tarballBuffer = zlib.gunzipSync(tarballDownloadBuffer)
    
    let downloadedCount = 0
    
    for (const binaryName of allBinaryNames) {
      const binaryData = extractFileFromTarball(tarballBuffer, `package/bin/${binaryName}`)
      
      if (binaryData) {
        const fallbackBinaryPath = path.join(__dirname, binaryName)
        fs.writeFileSync(fallbackBinaryPath, binaryData, { mode: 0o755 })
        console.log(`Binary downloaded and installed to ${fallbackBinaryPath}`)
        downloadedCount++
      }
    }
    
    if (downloadedCount === 0) {
      throw new Error(`No binaries found in package. Expected: ${allBinaryNames.join(', ')}`)
    }
    
    console.log(`Successfully downloaded ${downloadedCount} binary(ies)`)
  } catch (error) {
    console.error('Failed to download binary:', error.message)
    process.exit(1)
  }
}

if (!platformSpecificPackageName) {
  console.error(`Platform ${process.platform}-${process.arch} is not supported!`)
  process.exit(1)
}

if (!isPlatformSpecificPackageInstalled()) {
  console.log('Platform specific package not found. Will manually download binary.')
  downloadBinaryFromNpm()
} else {
  console.log('Platform specific package already installed.')
}
EOF

cat > "$MAIN_PACKAGE_DIR/bin/go-blueprint" << 'EOF'
#!/usr/bin/env node

const { execFileSync } = require('child_process')
const { getBinaryPath } = require('../utils')

try {
  const binaryPath = getBinaryPath()
  execFileSync(binaryPath, process.argv.slice(2), { stdio: 'inherit' })
} catch (error) {
  console.error('Failed to execute go-blueprint:', error.message)
  process.exit(1)
}
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
  "scripts": {
    "postinstall": "node install.js"
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
    "install.js",
    "index.js",
    "constants.js",
    "utils.js"
  ]
}
EOF

cat > "$MAIN_PACKAGE_DIR/index.js" << 'EOF'
const { execFileSync } = require('child_process')
const { getBinaryPath } = require('./utils')

module.exports = {
  getBinaryPath,
  run: function(...args) {
    const binaryPath = getBinaryPath()
    return execFileSync(binaryPath, args, { stdio: 'inherit' })
  }
}
EOF
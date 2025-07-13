#!/bin/bash

# Creates npm package structure for Go binary distribution

set -euo pipefail

readonly PACKAGE_NAME="go-blueprint"
readonly AUTHOR="abelpenton"
readonly REPO_URL="https://github.com/abelpenton/go-blueprint"
readonly BINARY_NAME="go-blueprint"
readonly CLI_NAME="go-blueprint"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

readonly VERSION="$1"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+.*$ ]]; then
    echo "Error: Invalid version format: $VERSION"
    exit 1
fi

echo "Creating npm package version: $VERSION"

rm -rf npm-package
mkdir -p npm-package
cd npm-package

cat > package.json << EOF
{
  "name": "$PACKAGE_NAME",
  "version": "$VERSION",
  "description": "Go Blueprint is a CLI tool that allows users to spin up a Go project with the corresponding structure seamlessly.",
  "bin": {
    "$CLI_NAME": "./bin/$CLI_NAME"
  },
  "scripts": {
    "postinstall": "node install.js"
  },
  "files": [
    "bin/",
    "install.js"
  ],
  "os": ["darwin", "linux", "win32"],
  "cpu": ["x64", "arm64"],
  "keywords": ["cli", "go-blueprint", "go"],
  "author": "$AUTHOR",
  "license": "MIT",
  "homepage": "$REPO_URL",
  "repository": {
    "type": "git",
    "url": "$REPO_URL.git"
  }
}
EOF

cp ../scripts/install.js ./

mkdir -p bin
cat > "bin/$CLI_NAME" << 'EOF'
#!/bin/bash
# This is a placeholder - the real binary will be downloaded by install.js
echo "Error: Binary not installed correctly. Please run: npm install"
exit 1
EOF
chmod +x "bin/$CLI_NAME"

echo "✓ npm package created successfully"
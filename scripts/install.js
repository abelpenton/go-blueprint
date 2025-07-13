const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const CONFIG = {
  binaryName: 'go-blueprint',
  cliName: 'go-blueprint',
  repoUrl: 'https://github.com/abelpenton/go-blueprint',
  maxRedirects: 5,
  platformMap: {
    'darwin': 'Darwin',
    'linux': 'Linux',
    'win32': 'Windows'
  },
  archMap: {
    'x64': 'x86_64',
    'arm64': 'arm64'
  }
};

class BinaryInstaller {
  constructor() {
    this.platform = process.platform;
    this.arch = process.arch;
    this.packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
    this.version = this.packageJson.version;
    
    this.mappedPlatform = CONFIG.platformMap[this.platform];
    this.mappedArch = CONFIG.archMap[this.arch];
    
    this.binaryName = this.platform === 'win32' ? `${CONFIG.binaryName}.exe` : CONFIG.binaryName;
    this.cliName = this.platform === 'win32' ? `${CONFIG.cliName}.exe` : CONFIG.cliName;
    

    const archiveFormat = this.platform === 'win32' ? 'zip' : 'tar.gz';
    
    // goreleaser name template: {{- .ProjectName }}_ {{- .Version }}_ {{- title .Os }}_ {{- if eq .Arch "amd64" }}x86_64 {{- else if eq .Arch "386" }}i386 {{- else }}{{ .Arch }}{{ end }}
    this.possibleArchiveNames = [
      `${CONFIG.binaryName}_${this.version}_${this.mappedPlatform}_${this.mappedArch}.${archiveFormat}`,
      `${CONFIG.binaryName}_v${this.version}_${this.mappedPlatform}_${this.mappedArch}.${archiveFormat}`,
      `${CONFIG.binaryName}_${this.mappedPlatform}_${this.mappedArch}.${archiveFormat}`,
      `${CONFIG.binaryName}_${this.platform}_${this.mappedArch}.${archiveFormat}`,
      `${CONFIG.binaryName}_${this.mappedPlatform.toLowerCase()}_${this.mappedArch}.${archiveFormat}`,
      `${CONFIG.binaryName}_${this.platform}_${this.arch}.${archiveFormat}`
    ];
    
    this.binDir = path.join(__dirname, 'bin');
    this.targetBinary = path.join(this.binDir, this.cliName);
  }

  validatePlatform() {
    if (!this.mappedPlatform || !this.mappedArch) {
      throw new Error(`Unsupported platform: ${this.platform}-${this.arch}`);
    }
  }

  isBinaryWorking() {
    if (!fs.existsSync(this.targetBinary)) {
      return false;
    }

    try {    
      try {
        execSync(`"${this.targetBinary}" --version`, { stdio: 'ignore' });
        return true;
      } catch {
        execSync(`"${this.targetBinary}" --help`, { stdio: 'ignore' });
        return true;
      }
    } catch (error) {
      console.log('Existing binary not working, reinstalling...');
      return false;
    }
  }

  prepareBinDirectory() {
    if (fs.existsSync(this.binDir)) {
      fs.rmSync(this.binDir, { recursive: true, force: true });
    }
    fs.mkdirSync(this.binDir, { recursive: true });
  }

  cleanupTempFiles() {
    this.possibleArchiveNames.forEach(archiveName => {
      const tempArchive = path.join(__dirname, archiveName);
      if (fs.existsSync(tempArchive)) {
        fs.unlinkSync(tempArchive);
      }
    });
  }

  downloadWithRedirects(url, maxRedirects = CONFIG.maxRedirects) {
    return new Promise((resolve, reject) => {
      const request = https.get(url, (response) => {
        if (response.statusCode === 302 || response.statusCode === 301) {
          if (maxRedirects > 0) {
            console.log(`Following redirect to: ${response.headers.location}`);
            this.downloadWithRedirects(response.headers.location, maxRedirects - 1)
              .then(resolve)
              .catch(reject);
            return;
          } else {
            reject(new Error('Too many redirects'));
            return;
          }
        }
        
        if (response.statusCode !== 200) {
          reject(new Error(`Failed to download: ${response.statusCode} ${response.statusMessage}`));
          return;
        }
        
        const archiveName = url.split('/').pop();
        const tempArchive = path.join(__dirname, archiveName);
        const file = fs.createWriteStream(tempArchive);
        response.pipe(file);
        
        file.on('finish', () => {
          file.close();
          resolve(tempArchive);
        });
        
        file.on('error', (error) => {
          fs.unlink(tempArchive, () => {});
          reject(error);
        });
      });
      
      request.on('error', (error) => {
        reject(error);
      });
    });
  }

  async tryDownloadArchive() {
    let lastError;
    
    for (const archiveName of this.possibleArchiveNames) {
      const downloadUrl = `${CONFIG.repoUrl}/releases/download/v${this.version}/${archiveName}`;
      
      try {
        console.log(`Trying to download: ${downloadUrl}`);
        const tempArchive = await this.downloadWithRedirects(downloadUrl);
        return tempArchive;
      } catch (error) {
        console.log(`Failed to download ${archiveName}: ${error.message}`);
        lastError = error;
        continue;
      }
    }
    
    throw lastError || new Error('No suitable archive found');
  }

  extractArchive(tempArchive) {
    try {
      const isZip = tempArchive.endsWith('.zip');
      
      if (isZip) {
        // Handle ZIP files (Windows)
        if (this.platform === 'win32') {
          try {
            // Try PowerShell first on Windows
            execSync(`powershell -command "Expand-Archive -Path '${tempArchive}' -DestinationPath '.' -Force"`, { stdio: 'inherit' });
          } catch (psError) {
            console.log('PowerShell extraction failed, trying tar...');
            try {
              execSync(`tar -xf "${tempArchive}"`, { stdio: 'inherit' });
            } catch (tarError) {
              throw new Error(`Both PowerShell and tar extraction failed: ${psError.message}`);
            }
          }
        } else {
          // On Unix-like systems, try unzip command
          try {
            execSync(`unzip -o "${tempArchive}"`, { stdio: 'inherit' });
          } catch (unzipError) {
            // Fallback to tar if unzip is not available
            execSync(`tar -xf "${tempArchive}"`, { stdio: 'inherit' });
          }
        }
      } else {
        // Handle TAR.GZ files (Linux/macOS)
        if (this.platform === 'win32') {        
          try {
            execSync(`tar -xzf "${tempArchive}"`, { stdio: 'inherit' });
          } catch (tarError) {
            console.log('tar command failed, trying PowerShell...');
            execSync(`powershell -command "tar -xzf '${tempArchive}'"`, { stdio: 'inherit' });
          }
        } else {
          execSync(`tar -xzf "${tempArchive}"`, { stdio: 'inherit' });
        }
      }
    } catch (error) {
      throw new Error(`Extraction failed: ${error.message}`);
    }
  }

  findExtractedBinary() {
    const possiblePaths = [
      path.join(__dirname, this.binaryName),
      path.join(__dirname, CONFIG.binaryName),
      path.join(__dirname, `${CONFIG.binaryName}_${this.version}_${this.mappedPlatform}_${this.mappedArch}`, this.binaryName),
      path.join(__dirname, `${CONFIG.binaryName}_v${this.version}_${this.mappedPlatform}_${this.mappedArch}`, this.binaryName),
      path.join(__dirname, `${CONFIG.binaryName}_${this.mappedPlatform}_${this.mappedArch}`, this.binaryName),
      path.join(__dirname, `${CONFIG.binaryName}_${this.platform}_${this.mappedArch}`, this.binaryName)
    ];

    for (const possiblePath of possiblePaths) {
      if (fs.existsSync(possiblePath)) {
        return possiblePath;
      }
    }

    console.log('Available files after extraction:', fs.readdirSync(__dirname));
    
    const files = fs.readdirSync(__dirname);
    for (const file of files) {
      const filePath = path.join(__dirname, file);
      try {
        const stat = fs.statSync(filePath);
        if (stat.isFile() && (file.includes(CONFIG.binaryName) || file.endsWith('.exe'))) {
          return filePath;
        }
        // Also check inside directories
        if (stat.isDirectory()) {
          const dirFiles = fs.readdirSync(filePath);
          for (const dirFile of dirFiles) {
            if (dirFile === this.binaryName || dirFile === CONFIG.binaryName) {
              return path.join(filePath, dirFile);
            }
          }
        }
      } catch (e) {
        // Ignore stat errors
      }
    }

    throw new Error('Binary not found in extracted archive');
  }

  installBinary() {
    const extractedBinary = this.findExtractedBinary();
    
    console.log(`Found binary at: ${extractedBinary}`);
    fs.renameSync(extractedBinary, this.targetBinary);
    
    if (this.platform !== 'win32') {
      fs.chmodSync(this.targetBinary, '755');
    }
  }

  cleanupExtractedFiles() {
    try {
      const files = fs.readdirSync(__dirname);
      files.forEach(file => {
        if (!['package.json', 'install.js', 'bin', 'README.md', 'node_modules'].includes(file)) {
          const filePath = path.join(__dirname, file);
          try {
            const stat = fs.statSync(filePath);
            if (stat.isFile()) {
              fs.unlinkSync(filePath);
            } else if (stat.isDirectory()) {
              fs.rmSync(filePath, { recursive: true, force: true });
            }
          } catch (e) {
            // Ignore cleanup errors
          }
        }
      });
    } catch (cleanupError) {
      console.warn('Warning: Could not clean up temp files:', cleanupError.message);
    }
  }

  async install() {
    try {
      this.validatePlatform();

      if (this.isBinaryWorking()) {
        console.log('Binary already installed and working!');
        return;
      }

      console.log(`Installing ${CONFIG.binaryName} v${this.version} for ${this.platform}-${this.arch}...`);
      
      this.prepareBinDirectory();
      this.cleanupTempFiles();
      
      const tempArchive = await this.tryDownloadArchive();
      
      this.extractArchive(tempArchive);
      this.installBinary();
      
      console.log('Installation completed successfully!');
      
    } catch (error) {
      console.error('Installation failed:', error.message);
      console.error('Make sure the release exists at:', `${CONFIG.repoUrl}/releases/tag/v${this.version}`);
      process.exit(1);
    } finally {
      this.cleanupTempFiles();
      this.cleanupExtractedFiles();
    }
  }
}

const installer = new BinaryInstaller();
installer.install();
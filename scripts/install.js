const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const CONFIG = {
  binaryName: 'go-blueprint',
  cliName: 'go-blueprint',
  repoUrl: 'https://github.com/Melkeydev/go-blueprint',
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
    this.archiveName = `${CONFIG.binaryName}_${this.mappedPlatform}_${this.mappedArch}.tar.gz`;
    this.downloadUrl = `${CONFIG.repoUrl}/releases/download/v${this.version}/${this.archiveName}`;
    
    this.binDir = path.join(__dirname, 'bin');
    this.targetBinary = path.join(this.binDir, this.cliName);
    this.tempArchive = path.join(__dirname, this.archiveName);
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
    if (fs.existsSync(this.tempArchive)) {
      fs.unlinkSync(this.tempArchive);
    }
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
        
        const file = fs.createWriteStream(this.tempArchive);
        response.pipe(file);
        
        file.on('finish', () => {
          file.close();
          resolve();
        });
        
        file.on('error', (error) => {
          fs.unlink(this.tempArchive, () => {});
          reject(error);
        });
      });
      
      request.on('error', (error) => {
        reject(error);
      });
    });
  }

  extractArchive() {
    try {
      if (this.platform === 'win32') {        
        try {
          execSync(`tar -xzf "${this.tempArchive}"`, { stdio: 'inherit' });
        } catch (tarError) {
          console.log('tar command failed, trying PowerShell...');
          execSync(`powershell -command "tar -xzf '${this.tempArchive}'"`, { stdio: 'inherit' });
        }
      } else {
        execSync(`tar -xzf "${this.tempArchive}"`, { stdio: 'inherit' });
      }
    } catch (error) {
      throw new Error(`Extraction failed: ${error.message}`);
    }
  }

  installBinary() {
    const extractedBinary = path.join(__dirname, this.binaryName);
    
    if (!fs.existsSync(extractedBinary)) {
      console.log('Available files:', fs.readdirSync(__dirname));
      throw new Error('Binary not found in extracted archive');
    }

    fs.renameSync(extractedBinary, this.targetBinary);
    
    if (this.platform !== 'win32') {
      fs.chmodSync(this.targetBinary, '755');
    }
  }

  cleanupExtractedFiles() {
    try {
      const files = fs.readdirSync(__dirname);
      files.forEach(file => {
        if (!['package.json', 'install.js', 'bin', 'README.md'].includes(file)) {
          const filePath = path.join(__dirname, file);
          try {
            const stat = fs.statSync(filePath);
            if (stat.isFile()) {
              fs.unlinkSync(filePath);
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

      console.log(`Downloading ${this.downloadUrl}...`);
      
      this.prepareBinDirectory();
      this.cleanupTempFiles();
      
      await this.downloadWithRedirects(this.downloadUrl);
      
      this.extractArchive();
      this.installBinary();
      
      console.log('Installation completed successfully!');
      
    } catch (error) {
      console.error('Installation failed:', error.message);
      process.exit(1);
    } finally {
      this.cleanupTempFiles();
      this.cleanupExtractedFiles();
    }
  }
}

const installer = new BinaryInstaller();
installer.install();
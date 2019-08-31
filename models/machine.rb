# encoding: utf-8
#
# For more information about Backup's components, see the documentation at:
# http://backup.github.io/backup
#

require 'dotenv'
require 'mkmf'
require 'paint'
require 'shellwords'
require 'which_works'

Dotenv.load!

%i(GPG_KEY AWS_REGION AWS_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY).each do |name|
  raise "$BACKUP_MACHINE_#{name} must be set!" unless ENV["BACKUP_MACHINE_#{name}"]
end

%i(PATH).each do |name|
  raise "$BACKUP_DATA_#{name} must be set!" unless ENV["BACKUP_DATA_#{name}"]
end

%i(PATH).each do |name|
  raise "$BACKUP_DOCUMENTS_#{name} must be set!" unless ENV["BACKUP_DOCUMENTS_#{name}"]
end

BACKUP_TMP_DIR = Dir.mktmpdir

BACKUP_MACHINE_LISTED_DIRECTORIES = %w(/Applications /Applications/Utilities Downloads Library/LaunchAgents Machines Projects)
BACKUP_MACHINE_CONFIGURATION_FILES = %w(/etc/hosts .bash_profile .gitlocal .gitprivate .gnupg/gpg.conf .gnupg/gpg-agent.conf .httpie/config.json .zshconfig)

BACKUP_DATA_DIRECTORIES = %w(Documents Scans Work)
BACKUP_DOCUMENTS_DIRECTORIES = %w(Archives Automator Config Documents Playground Projects Servers)

Signal.trap 'EXIT' do
  FileUtils.remove_entry_secure BACKUP_TMP_DIR
end

preconfigure 'MachineModel' do
  compress_with Gzip do |compression|
    compression.level = 9
  end

  encrypt_with GPG do |encryption|

    key_name = ENV['BACKUP_MACHINE_GPG_KEY']

    encryption.keys = {}
    encryption.keys[key_name] = `gpg --export --armor #{Shellwords.shellescape(key_name)}`

    encryption.recipients = key_name
  end

  unless ENV['BACKUP_LOCAL_ONLY']
    store_with S3 do |s3|
      s3.access_key_id = ENV['BACKUP_MACHINE_AWS_ACCESS_KEY_ID']
      s3.secret_access_key = ENV['BACKUP_MACHINE_AWS_SECRET_ACCESS_KEY']
      s3.region = ENV['BACKUP_MACHINE_AWS_REGION']
      s3.bucket = ENV['BACKUP_MACHINE_AWS_BUCKET']
      s3.path = 'backup'
      s3.chunk_size = 10
    end
  end
end

MachineModel.new :data, 'Backup of data' do
  archive :data do |archive|
    archive.root ENV['BACKUP_DATA_PATH']
    BACKUP_DATA_DIRECTORIES.each do |dir|
      archive.add dir
    end
  end
end

MachineModel.new :documents, 'Backup of documents' do
  archive :documents do |archive|
    archive.root ENV['BACKUP_DOCUMENTS_PATH']
    BACKUP_DOCUMENTS_DIRECTORIES.each do |dir|
      archive.add dir
    end
  end

  store_with Local do |local|
    local.path = '~/Backup/local'
    local.keep = 3
  end
end

MachineModel.new :vault, 'Backup of archives' do
  archive :vault do |archive|
    archive.root ENV['BACKUP_DOCUMENTS_PATH']
    archive.add 'Vault'
  end
end

MachineModel.new :machine, 'Backup of the local machine\'s configuration' do

  before do

    installation_dir = File.join BACKUP_TMP_DIR, 'installation'
    FileUtils.mkdir_p installation_dir

    BACKUP_MACHINE_LISTED_DIRECTORIES.each do |dir|
      absolute_path = File.expand_path dir, '~'
      list_path = File.join installation_dir, "#{File.basename(dir)}.txt"
      if not File.directory? absolute_path
        Logger.info Paint[%/Directory "#{absolute_path}" does not exist, skipping.../, :cyan]
      elsif not system "ls #{Shellwords.shellescape(absolute_path)} > #{Shellwords.shellescape(list_path)}"
        raise "Could not list directory #{dir}"
      end
    end

    if Which.which 'port'
      list_path = File.join installation_dir, 'macports.txt'
      if not system "port installed > #{Shellwords.shellescape(list_path)}"
        raise 'Could not list installed ports'
      end
    else
      Logger.info Paint['MacPorts not available, skipping...', :cyan]
    end

    if Which.which 'brew'

      list_path = File.join installation_dir, 'homebrew.txt'
      if not system "brew list --versions > #{Shellwords.shellescape(list_path)}"
        raise 'Could not list installed packages with Homebrew'
      end

      cask_list_path = File.join installation_dir, 'homebrew-cask.txt'
      if not system "brew cask list --versions > #{Shellwords.shellescape(cask_list_path)}"
        raise 'Could not list installed casks with Homebrew'
      end
    else
      Logger.info Paint['Homebrew not available, skipping...', :cyan]
    end

    if Which.which 'gem'
      gems_path = File.join installation_dir, 'gems.txt'
      if not system "gem list > #{Shellwords.shellescape(gems_path)}"
        raise 'Could not list installed Ruby gems'
      end
    else
      Logger.info Paint['gem executable not available, skipping...', :cyan]
    end

    if Which.which 'npm'
      npm_packages_path = File.join installation_dir, 'npm.txt'
      # Note: npm list returns a non-zero status code if peer dependencies are not met
      if not system "npm list --global --depth 0 > #{Shellwords.shellescape(npm_packages_path)} || true"
        raise 'Could not list installed npm packages'
      end
    else
      Logger.info Paint['npm executable not available, skipping...', :cyan]
    end
  end

  archive :installation do |archive|
    archive.root File.join(BACKUP_TMP_DIR, 'installation')
    archive.add '.'
  end

  archive :configuration do |archive|

    homebrew_configuration_files = '/usr/local/etc'
    if File.directory? homebrew_configuration_files
      archive.add homebrew_configuration_files
    else
      Logger.info Paint[%/Homebrew configuration directory "#{homebrew_configuration_files}" not available, skipping.../, :cyan]
    end

    Dir.glob('/usr/local/var/postgres/*.conf').each do |file|
      archive.add file
    end

    BACKUP_MACHINE_CONFIGURATION_FILES.each do |file|
      absolute_path = File.expand_path file, '~'
      if File.exist? absolute_path
        archive.add absolute_path
      else
        Logger.info Paint[%/File "#{absolute_path}" does not exist, skipping.../, :cyan]
      end
    end
  end

  archive :history do |archive|

    home_dir = File.expand_path '~'
    archive.root home_dir

    Dir.chdir home_dir
    Dir.glob('.*history').each do |file|
      if File.file? file
        archive.add file
      end
    end
  end

  store_with Local do |local|
    local.path = '~/Backup/local'
    local.keep = 120
  end
end

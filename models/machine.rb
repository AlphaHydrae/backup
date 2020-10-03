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

BACKUP_MACHINE_LISTED_DIRECTORIES = %w(/Applications /Applications/Utilities Downloads Library/LaunchAgents Projects)
BACKUP_MACHINE_CONFIGURATION_FILES = %w(/etc/hosts .bash_profile .gitlocal .gitprivate .gnupg/gpg.conf .gnupg/gpg-agent.conf .httpie/config.json .tool-versions .zshconfig)

BACKUP_DATA_DIRECTORIES = %w(Documents Scans Work)
BACKUP_DOCUMENTS_DIRECTORIES = %w(Archives Automator Config Documents Playground Projects Servers)

class CustomBackup
  def self.archive_path(archive:, path:, name: nil)
    absolute_path = File.expand_path(path, '~')
    if File.file? absolute_path
      archive.add absolute_path
      Logger.info "Archived #{Paint[absolute_path, :green]}"
    else
      Logger.info Paint["#{name || 'File or directory'} '#{absolute_path}' not available, skipping...", :cyan]
    end
  end

  def self.back_up_command_output(command:, backup_dir:, backup_relative_path: nil)
    executable = command.first
    if Which.which executable
      escaped_command = command.map{ |word| Shellwords.shellescape word }.join(' ')
      escaped_absolute_path = Shellwords.shellescape(File.join(backup_dir, backup_relative_path || "#{executable}.txt"))
      if not system "#{escaped_command} > #{escaped_absolute_path}"
        raise "Failed to execute #{escaped_command} > #{escaped_absolute_path}"
      else
        Logger.info "#{Paint[escaped_command, :yellow]} -> #{Paint[escaped_absolute_path, :green]}"
      end
    else
      Logger.info Paint["Command '#{executable}' not available, skipping...", :cyan]
    end
  end
end

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
      absolute_dir_path = File.expand_path dir, '~'
      CustomBackup.back_up_command_output(command: [ 'ls', absolute_dir_path ], backup_dir: installation_dir, backup_relative_path: "#{File.basename(dir)}.txt")
    end

    CustomBackup.back_up_command_output(command: [ 'brew', 'list', '--versions' ], backup_dir: installation_dir)
    CustomBackup.back_up_command_output(command: [ 'gem', 'list' ], backup_dir: installation_dir)
    CustomBackup.back_up_command_output(command: [ 'npm', 'list', '--global', '--depth', '0' ], backup_dir: installation_dir)
  end

  archive :installation do |archive|
    archive.root File.join(BACKUP_TMP_DIR, 'installation')
    archive.add '.'
  end

  archive :configuration do |archive|
    CustomBackup.archive_path(archive: archive, path: '/usr/local/etc', name: 'Homebrew configuration directory')

    Dir.glob('/usr/local/var/postgres/*.conf').each do |file|
      CustomBackup.archive_path(archive: archive, path: file)
    end

    BACKUP_MACHINE_CONFIGURATION_FILES.each do |file|
      CustomBackup.archive_path(archive: archive, path: file)
    end
  end

  archive :history do |archive|

    home_dir = File.expand_path '~'
    archive.root home_dir

    Dir.chdir home_dir
    Dir.glob('.*history').select{ |f| File.file?(f) }.each do |file|
      CustomBackup.archive_path(archive: archive, path: file)
    end
  end

  store_with Local do |local|
    local.path = '~/Backup/local'
    local.keep = 120
  end
end

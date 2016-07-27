# encoding: utf-8
#
# For more information about Backup's components, see the documentation at:
# http://backup.github.io/backup
#

require 'dotenv'
require 'shellwords'

Dotenv.load!

%i(GPG_KEY AWS_REGION AWS_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY).each do |name|
  raise "$BACKUP_MACHINE_#{name} must be set!" unless ENV["BACKUP_MACHINE_#{name}"]
end

BACKUP_TMP_DIR = Dir.mktmpdir
BACKUP_MACPORTS_BIN = '/opt/local/bin/port'
BACKUP_HOMEBREW_BIN = '/usr/local/bin/brew'

BACKUP_MACHINE_LISTED_DIRECTORIES = %w(/Applications /Applications/Utilities Downloads Machines Projects Projects/ansible-roles)
BACKUP_MACHINE_CONFIGURATION_FILES = %w(.httpie/config.json .zshconfig)

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
end

MachineModel.new(:machine, 'Backup of the local machine\'s configuration') do

  before do

    installation_dir = File.join BACKUP_TMP_DIR, 'installation'
    FileUtils.mkdir_p installation_dir

    BACKUP_MACHINE_LISTED_DIRECTORIES.each do |dir|
      absolute_path = File.expand_path dir, '~'
      list_path = File.join installation_dir, "#{File.basename(dir)}.txt"
      system "ls #{Shellwords.shellescape(absolute_path)} > #{Shellwords.shellescape(list_path)}"
    end

    if File.executable? BACKUP_MACPORTS_BIN
      list_path = File.join installation_dir, 'macports.txt'
      system "#{BACKUP_MACPORTS_BIN} installed > #{Shellwords.shellescape(list_path)}"
    end

    if File.executable? BACKUP_HOMEBREW_BIN
      list_path = File.join installation_dir, 'homebrew.txt'
      system "#{BACKUP_HOMEBREW_BIN} list --versions > #{Shellwords.shellescape(list_path)}"
    end
  end

  archive :installation do |archive|

    archive.root File.join(BACKUP_TMP_DIR, 'installation')
    BACKUP_MACHINE_LISTED_DIRECTORIES.each do |dir|
      archive.add "#{File.basename(dir)}.txt"
    end

    archive.add 'macports.txt' if File.executable? BACKUP_MACPORTS_BIN
    archive.add 'homebrew.txt' if File.executable? BACKUP_HOMEBREW_BIN
  end

  archive :configuration do |archive|

    homebrew_configuration_files = '/usr/local/etc'
    archive.add homebrew_configuration_files if File.directory? homebrew_configuration_files

    Dir.glob('/usr/local/var/postgres/*.conf').each do |file|
      archive.add file
    end

    BACKUP_MACHINE_CONFIGURATION_FILES.each do |file|
      absolute_path = File.expand_path file, '~'
      archive.add absolute_path
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

  store_with S3 do |s3|
    s3.access_key_id = ENV['BACKUP_MACHINE_AWS_ACCESS_KEY_ID']
    s3.secret_access_key = ENV['BACKUP_MACHINE_AWS_SECRET_ACCESS_KEY']
    s3.region = ENV['BACKUP_MACHINE_AWS_REGION']
    s3.bucket = ENV['BACKUP_MACHINE_AWS_BUCKET']
    s3.path = ''
    s3.chunk_size = 10
  end

  store_with Local do |local|
    local.path = '~/Backup/local'
    local.keep = 120
  end
end

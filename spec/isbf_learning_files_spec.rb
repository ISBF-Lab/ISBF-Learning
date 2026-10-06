# frozen_string_literal: true

require "tmpdir"

RSpec.describe IsbfLearning::Files do
  fab!(:user)

  let(:guardian) { Guardian.new(user) }

  before do
    @storage_root = Dir.mktmpdir("isbf-private-files")
    @incoming = []
    described_class.stubs(:root).returns(@storage_root)
    IsbfLearning.stubs(:ensure_can_submit!).with(user, guardian).returns(true)
    SiteSetting.authorized_extensions = "pdf|txt"
    SiteSetting.max_attachment_size_kb = 2048
    SiteSetting.isbf_learning_storage_limit_mb = 1
  end

  after do
    @incoming.each(&:close!)
    FileUtils.remove_entry(@storage_root)
  end

  def incoming(contents = "private study notes", name = "notes.txt")
    tempfile = Tempfile.new("isbf-incoming")
    tempfile.binmode
    tempfile.write(contents)
    tempfile.rewind
    @incoming << tempfile
    ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: name, type: "application/octet-stream")
  end

  def storage_bytes
    PluginStore.get(IsbfLearning::STORE, described_class::QUOTA_KEY)
  end

  it "stores private metadata and bytes without creating a native upload" do
    result = nil
    expect { result = described_class.upload(user, guardian, incoming) }.not_to change(Upload, :count)
    expect(result).to include(name: "notes.txt", size: 19, original_filename: "notes.txt", extension: "txt", filesize: 19)
    expect(result[:url]).to eq("/isbf/learning/files/#{result[:id]}")
    expect(result[:short_url]).to eq(result[:url])
    expect(File.binread(described_class.path(result[:id]))).to eq("private study notes")
    expect(File.stat(described_class.path(result[:id])).mode & 0o777).to eq(0o600)
    expect(described_class.metadata(result[:id])).to eq(id: result[:id], name: "notes.txt", size: 19, owner_id: user.id, url: result[:url])
    expect(storage_bytes).to eq(19)
  end

  it "checks submission access before validation or storage" do
    IsbfLearning.expects(:ensure_can_submit!).with(user, guardian).raises(Discourse::InvalidAccess)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(Discourse::InvalidAccess)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "rejects anonymous uploads" do
    expect { described_class.upload(nil, Guardian.new, incoming) }.to raise_error(Discourse::InvalidAccess)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "uses the native upload rate limiter" do
    limiter = mock("rate limiter")
    RateLimiter.expects(:new).with(user, "uploads-per-minute", SiteSetting.max_uploads_per_minute, 60).returns(limiter)
    limiter.expects(:performed!).raises(RateLimiter::LimitExceeded.new(60))
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(RateLimiter::LimitExceeded)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "enforces the native file extension policy" do
    expect { described_class.upload(user, guardian, incoming("script", "script.exe")) }.to raise_error(IsbfLearning::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "enforces the native attachment size policy" do
    SiteSetting.max_attachment_size_kb = 1
    expect { described_class.upload(user, guardian, incoming("x" * 1025)) }.to raise_error(IsbfLearning::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "rejects empty uploads" do
    expect { described_class.upload(user, guardian, incoming("")) }.to raise_error(IsbfLearning::StorageError)
  end

  it "enforces the total quota across successive uploads and removes pending bytes" do
    first = described_class.upload(user, guardian, incoming("x" * (1024 * 1024)))
    expect { described_class.upload(user, guardian, incoming("x")) }.to raise_error(IsbfLearning::StorageError)
    expect(Dir.children(@storage_root)).to eq([first[:id]])
    expect(storage_bytes).to eq(1024 * 1024)
  end

  it "caps storage at 512 MiB even when the site setting is larger" do
    SiteSetting.stubs(:isbf_learning_storage_limit_mb).returns(1024)
    PluginStore.set(IsbfLearning::STORE, described_class::QUOTA_KEY, 512 * 1024 * 1024)
    expect { described_class.upload(user, guardian, incoming("x")) }.to raise_error(IsbfLearning::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "rolls back quota and removes the file when metadata cannot be saved" do
    PluginStore.set(IsbfLearning::STORE, described_class::QUOTA_KEY, 0)
    PluginStore.stubs(:set).returns(false)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfLearning::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
    expect(storage_bytes).to eq(0)
    expect(PluginStoreRow.where(plugin_name: IsbfLearning::STORE).where("key LIKE ?", "file:%")).to be_empty
  end

  it "removes the file and rolls back metadata when updating quota fails" do
    PluginStoreRow.any_instance.stubs(:update!).raises(ActiveRecord::StatementInvalid)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(Dir.children(@storage_root)).to be_empty
    expect(PluginStoreRow.where(plugin_name: IsbfLearning::STORE).where("key LIKE ?", "file:%")).to be_empty
  end

  it "converts disk exhaustion to a storage error and removes temporary bytes" do
    File.stubs(:rename).raises(Errno::ENOSPC)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfLearning::StorageError, "Private file storage is unavailable")
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "rejects traversal, malformed UUIDs, and encoded paths" do
    ["../secret", "/etc/passwd", "%2e%2e%2fsecret", SecureRandom.uuid + "/../secret", nil].each do |id|
      expect { described_class.path(id) }.to raise_error(Discourse::InvalidParameters)
    end
  end

  it "rejects publicly served storage roots" do
    described_class.stubs(:root).returns(Rails.root.join("public", "private-learning").to_s)
    expect { described_class.path(SecureRandom.uuid) }.to raise_error(IsbfLearning::StorageError)
  end

  it "strips directory components from display names" do
    result = described_class.upload(user, guardian, incoming("notes", "C:\\private\\notes.txt"))
    expect(result[:name]).to eq("notes.txt")
  end

  it "requires explicit file access before returning a download path" do
    result = described_class.upload(user, guardian, incoming)
    IsbfLearning.expects(:file_accessible?).with(result[:id], user, guardian).returns(false)
    expect { described_class.download(result[:id], user, guardian) }.to raise_error(Discourse::InvalidAccess)
  end

  it "returns a download only after the current guardian passes access checks" do
    result = described_class.upload(user, guardian, incoming)
    IsbfLearning.expects(:file_accessible?).with(result[:id], user, guardian).returns(true)
    expect(described_class.download(result[:id], user, guardian)).to eq(path: described_class.path(result[:id]), name: "notes.txt", size: 19)
  end

  it "does not let anonymous users download even when metadata exists" do
    result = described_class.upload(user, guardian, incoming)
    IsbfLearning.expects(:file_accessible?).never
    expect { described_class.download(result[:id], nil, Guardian.new) }.to raise_error(Discourse::InvalidAccess)
  end

  it "reports missing disk files after authorization" do
    result = described_class.upload(user, guardian, incoming)
    File.unlink(described_class.path(result[:id]))
    IsbfLearning.stubs(:file_accessible?).returns(true)
    expect { described_class.download(result[:id], user, guardian) }.to raise_error(Discourse::NotFound)
  end
end

# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "bin/live-examples" do # rubocop:disable RSpec/DescribeClass
  let(:script) { File.expand_path("../../bin/live-examples", __dir__) }
  let(:examples_dir) { Dir.mktmpdir("live-examples-scripts") }
  let(:log_dir) { Dir.mktmpdir("live-examples-logs") }

  after do
    FileUtils.rm_rf([examples_dir, log_dir])
  end

  def write_example(name, body)
    File.write(File.join(examples_dir, name), body)
  end

  def run_runner(extra_env = {})
    env = {
      "COOLHAND_EXAMPLES_NO_ZSH" => "1",
      "COOLHAND_EXAMPLES_DIR" => examples_dir,
      "COOLHAND_EXAMPLES_LOG_DIR" => log_dir
    }.merge(extra_env)
    Open3.capture3(env, RbConfig.ruby, script)
  end

  it "reports PASS and exits 0 when every script succeeds" do
    write_example("ok.rb", 'puts "COOLHAND: 📤 Sent complete request/response log for abc"')

    out, _err, status = run_runner

    expect(out).to match(/^PASS\s+ok\.rb/)
    expect(status.exitstatus).to eq(0)
  end

  it "reports SKIP, not FAIL, for a missing-key skip and exits 0 with a warning" do
    write_example("skipped.rb", 'puts "Skipping skipped.rb — OPENAI_API_KEY not set."')

    out, err, status = run_runner

    expect(out).to match(/^SKIP\s+skipped\.rb/)
    expect(err).to include("no live call was made")
    expect(status.exitstatus).to eq(0)
  end

  it "reports PASS for a script that skips only part of its work" do
    write_example("partial.rb", %(puts "  PASS  local scenario"\nputs "Skipping live scenario — no key."))

    out, _err, status = run_runner

    expect(out).to match(/^PASS\s+partial\.rb/)
    expect(status.exitstatus).to eq(0)
  end

  it "reports FAIL and exits 1 on a non-zero exit" do
    write_example("broken.rb", "exit 3")

    out, _err, status = run_runner

    expect(out).to match(/^FAIL\s+broken\.rb/)
    expect(status.exitstatus).to eq(1)
  end

  it "reports FAIL when a delivery-failed marker appears despite exit 0" do
    write_example("undelivered.rb", 'puts "COOLHAND: ❌ Request failed: 401 - nope"')

    out, _err, status = run_runner

    expect(out).to match(/^FAIL\s+undelivered\.rb/)
    expect(status.exitstatus).to eq(1)
  end

  it "writes one log file per script" do
    write_example("logged.rb", 'puts "hello from logged"')

    run_runner

    expect(File.read(File.join(log_dir, "logged.log"))).to include("hello from logged")
  end

  it "runs scripts concurrently" do
    # Each script waits for the other's marker file, so this only passes if both run at once.
    2.times do |i|
      write_example("peer#{i}.rb", <<~RUBY)
        require "fileutils"
        FileUtils.touch(File.join(#{log_dir.inspect}, "started#{i}"))
        deadline = Time.now + 20
        sleep 0.05 until File.exist?(File.join(#{log_dir.inspect}, "started#{1 - i}")) || Time.now > deadline
        exit(File.exist?(File.join(#{log_dir.inspect}, "started#{1 - i}")) ? 0 : 1)
      RUBY
    end

    out, _err, status = run_runner

    expect(out).to match(/2 passed/)
    expect(status.exitstatus).to eq(0)
  end

  it "does not warn when only some scripts are skipped" do
    write_example("ok.rb", 'puts "fine"')
    write_example("skipped.rb", 'puts "Skipping skipped.rb — OPENAI_API_KEY not set."')

    out, err, status = run_runner

    expect(out).to match(/1 passed, 1 skipped, 0 failed/)
    expect(err).not_to include("no live call was made")
    expect(status.exitstatus).to eq(0)
  end

  it "prints the tail of a failing script's log" do
    write_example("broken.rb", 'puts "boom-detail"; exit 2')

    out, _err, _status = run_runner

    expect(out).to include("--- broken.rb").and include("boom-detail")
  end

  it "exits 1 when there are no scripts to run" do
    _out, err, status = run_runner

    expect(err).to include("no scripts found")
    expect(status.exitstatus).to eq(1)
  end

  it "reports FAIL for a script that outlives COOLHAND_EXAMPLES_TIMEOUT" do
    write_example("hang.rb", "sleep 30")

    out, _err, status = run_runner("COOLHAND_EXAMPLES_TIMEOUT" => "1")

    expect(out).to match(/^FAIL\s+hang\.rb/)
    expect(File.read(File.join(log_dir, "hang.log"))).to include("timed out after 1.0s")
    expect(status.exitstatus).to eq(1)
  end

  it "tightens a leftover log file to owner-only" do
    File.write(File.join(log_dir, "logged.log"), "stale")
    File.chmod(0o644, File.join(log_dir, "logged.log"))
    write_example("logged.rb", 'puts "hi"')

    run_runner

    expect(File.stat(File.join(log_dir, "logged.log")).mode & 0o077).to eq(0)
  end

  it "creates a new log directory owner-only" do
    nested_log_dir = File.join(log_dir, "nested")
    write_example("logged.rb", 'puts "hi"')

    run_runner("COOLHAND_EXAMPLES_LOG_DIR" => nested_log_dir)

    expect(File.stat(nested_log_dir).mode & 0o077).to eq(0)
  end

  it "tightens a leftover log directory to owner-only" do
    File.chmod(0o755, log_dir)
    write_example("logged.rb", 'puts "hi"')

    run_runner

    expect(File.stat(log_dir).mode & 0o077).to eq(0)
  end

  it "exits 2 with a clear message for an invalid COOLHAND_EXAMPLES_TIMEOUT" do
    write_example("ok.rb", 'puts "fine"')

    ["abc", "0", "-5"].each do |bad|
      _out, err, status = run_runner("COOLHAND_EXAMPLES_TIMEOUT" => bad)

      expect(err).to include("COOLHAND_EXAMPLES_TIMEOUT must be a positive number")
      expect(status.exitstatus).to eq(2)
    end
  end

  it "enforces the timeout even when a script leaves a child holding its output open" do
    write_example("orphan.rb", 'spawn("sleep 20"); sleep 60')

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, _err, status = run_runner("COOLHAND_EXAMPLES_TIMEOUT" => "1")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(out).to match(/^FAIL\s+orphan\.rb/)
    expect(status.exitstatus).to eq(1)
    expect(elapsed).to be < 12
  end

  it "does not wait on a child a successful script leaves holding its output open" do
    write_example("daemonizer.rb", 'spawn("sleep 20"); puts "done"')

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, _err, status = run_runner
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(out).to match(/^PASS\s+daemonizer\.rb/)
    expect(status.exitstatus).to eq(0)
    expect(elapsed).to be < 12
  end

  it "stops the running scripts when the runner is terminated" do
    pid_file = File.join(log_dir, "script.pid")
    write_example("long.rb", "File.write(#{pid_file.inspect}, Process.pid.to_s); sleep 60")
    env = { "COOLHAND_EXAMPLES_NO_ZSH" => "1", "COOLHAND_EXAMPLES_DIR" => examples_dir,
            "COOLHAND_EXAMPLES_LOG_DIR" => log_dir }
    runner = Process.spawn(env, RbConfig.ruby, script, %i[out err] => File::NULL)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    sleep 0.1 until (File.exist?(pid_file) && !File.empty?(pid_file)) ||
                    Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    script_pid = Integer(File.read(pid_file))

    Process.kill("TERM", runner)
    Process.wait(runner)
    sleep 0.2

    expect { Process.kill(0, script_pid) }.to raise_error(Errno::ESRCH)
  end

  context "when zsh is installed" do
    let(:zdotdir) { Dir.mktmpdir("live-examples-zdotdir") }

    before do
      skip "zsh not installed" unless system("command -v zsh > /dev/null 2>&1")
    end

    after { FileUtils.rm_rf(zdotdir) }

    it "re-execs under `zsh -ic` once so keys from the zsh profile are visible" do
      File.write(File.join(zdotdir, ".zshrc"), "export LIVE_EXAMPLES_FAKE_KEY=from-zshrc\n")
      write_example("env.rb", 'puts "KEY=#{ENV.fetch(\'LIVE_EXAMPLES_FAKE_KEY\', \'missing\')}"')

      out, _err, status = run_runner("COOLHAND_EXAMPLES_NO_ZSH" => nil, "ZDOTDIR" => zdotdir)

      expect(out.scan("re-running under `zsh -ic`").size).to eq(1)
      expect(File.read(File.join(log_dir, "env.log"))).to include("KEY=from-zshrc")
      expect(status.exitstatus).to eq(0)
    end
  end
end

# frozen_string_literal: true

if ENV["FIT_KIT_COVERAGE"] == "1"
  require "coverage"
  Coverage.start(lines: true)
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "fit_kit"

require "minitest/autorun"

if ENV["FIT_KIT_COVERAGE"] == "1"
  Minitest.after_run do
    lib_dir = File.expand_path("../lib", __dir__)
    files = Coverage.result.select { |path, _coverage| path.start_with?(lib_dir) && path.end_with?(".rb") }
    executable_lines = 0
    covered_lines = 0

    files.each_value do |coverage|
      coverage[:lines].each do |count|
        next if count.nil?

        executable_lines += 1
        covered_lines += 1 if count.positive?
      end
    end

    coverage_percent = executable_lines.zero? ? 100.0 : (covered_lines.to_f / executable_lines * 100)
    abort "Expected 100% Ruby line coverage, got #{coverage_percent.round(2)}%" unless covered_lines == executable_lines
  end
end

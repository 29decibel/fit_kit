# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

ENV["RUBOCOP_CACHE_ROOT"] ||= File.expand_path(".rubocop_cache", __dir__)

Minitest::TestTask.create

require "standard/rake"

task default: %i[test standard]

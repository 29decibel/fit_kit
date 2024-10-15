# frozen_string_literal: true

require "test_helper"

class TestFitKit < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::FitKit::VERSION
  end

  def test_it_does_something_useful
    assert_equal(::FitKit.hello("mike"), "Hello from Rust, mike!", "hello message should match")
  end

  def test_parse_fit_file
    file_path = "/Users/mikeli/projects/fit_kit/example.fit"
    a = ::FitKit.parse_fit_file(file_path)
    record = a[12]
    puts record.kind
    record.fields.each do |f|
      puts "name: #{f.name} -> #{f.value} (#{f.value.class})"
    end
  end
end

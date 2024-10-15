# frozen_string_literal: true

require "test_helper"
require "benchmark"

class TestFitKit < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::FitKit::VERSION
  end

  def test_parse_fit_file
    puts Dir.pwd
    test_fit_file = File.join(Dir.pwd, "test/fixtures/example.fit")
    fit_data_records = ::FitKit.parse_fit_file(test_fit_file)
    assert_equal(fit_data_records.size, 2378, "Parse fit file records should match")
    # check the record type
    record_type_items = fit_data_records.select { |record| record.kind == "record" }
    assert_equal(record_type_items.size, 2355, "Record kind items should match")
  end
end

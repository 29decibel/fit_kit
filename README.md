# FitKit

`fit_kit` is a small ruby gem wraps Rust's crate [fitparse-rs](https://github.com/stadelmanma/fitparse-rs) to provide effecient and fast Garmin fit files parsing.

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add fit_kit

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install fit_kit

## Usage

```ruby
test_fit_file = File.join(Dir.pwd, "example.fit")
fit_data_records = ::FitKit.parse_fit_file(test_fit_file)
# [RFitDataRecord, RFitDataRecord, RFitDataRecord ...]
```

## Performance
Here is the performance parsing __4090__ fit files on my M1 Mac Mini (16G, 8 Cores) took 6 seconds (in parallel):

```txt
❯ ruby app.rb
Parsing 4090 fit files...
       user     system      total        real
  0.129862   0.102642  45.192900 (  6.121117)
```

Code to parse a given folder (contains __4090__ fit files) in parallel:

```ruby
require 'fit_kit'
require 'benchmark'
require 'parallel'

def parse_concurrently
  puts "Parsing all fit files here"
  fit_files = Dir.glob("/Users/mikeli/docs/HealthFit/*.{fit,FIT}")
  puts "Parsing #{fit_files.size} fit files..."

  # Determine the number of processors
  num_processors = Parallel.processor_count

  # Parse files concurrently
  Parallel.each(fit_files, in_processes: num_processors) do |file|
    begin
      FitKit.parse_fit_file(file)
    rescue => e
      puts "Error parsing #{file}: #{e.message}"
    end
  end
end


Benchmark.bm do |x|
  x.report do
    parse_concurrently
  end
end

```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/29decibel/fit_kit. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/29decibel/fit_kit/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the FitKit project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/29decibel/fit_kit/blob/main/CODE_OF_CONDUCT.md).

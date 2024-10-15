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

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/29decibel/fit_kit. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/29decibel/fit_kit/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the FitKit project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/29decibel/fit_kit/blob/main/CODE_OF_CONDUCT.md).

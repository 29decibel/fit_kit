use fitparser::{self, profile::MesgNum, FitDataField, FitDataRecord, Value};
use itertools::Itertools;
use magnus::{function, method, prelude::*, Error, IntoValue, RArray, RHash, Ruby, Symbol};
use std::fs::File;

// wrap fitparse value
struct MyValue(Value);

impl MyValue {
    // turn value into f64
    fn as_f64(&self) -> Option<f64> {
        match &self.0 {
            Value::SInt8(i) => Some(*i as f64),
            Value::UInt8(u) => Some(*u as f64),
            Value::SInt16(i) => Some(*i as f64),
            Value::UInt16(u) => Some(*u as f64),
            Value::SInt32(i) => Some(*i as f64),
            Value::UInt32(u) => Some(*u as f64),
            Value::Float32(f) => Some(*f as f64),
            Value::Float64(f) => Some(*f),
            Value::UInt8z(u) => Some(*u as f64),
            Value::UInt16z(u) => Some(*u as f64),
            Value::UInt32z(u) => Some(*u as f64),
            Value::SInt64(i) => Some(*i as f64),
            Value::UInt64(u) => Some(*u as f64),
            Value::UInt64z(u) => Some(*u as f64),
            _ => None, // Handle any other variants that don't convert to f64
        }
    }
}

#[magnus::wrap(class = "FitParseResult")]
struct FitParseResult(Vec<FitDataRecord>);

impl FitParseResult {
    /**
     * Returns Ruby hash for all the records
     * With keys are the record types
     */
    fn records_hash(&self) -> RHash {
        // now let's group by the record by kind
        let result_hash = RHash::new();
        for (kind, kind_records) in self
            .0
            .iter()
            .chunk_by(|record| record.kind().to_string())
            .into_iter()
        {
            // turn records into rarray
            let array = RArray::new();
            for record in kind_records {
                // TODO here do not pass RFitDataRecord
                // turn it into fields_hash directly
                array.push(get_fields_hash(record)).unwrap();
            }

            result_hash.aset(Symbol::new(kind), array).unwrap();
        }

        result_hash
    }

    // summary methods
    fn avg_for(&self, field_name: String) -> (f64, String) {
        // passing the reference
        self.avg_for_records(&self.0, field_name)
    }

    fn elevation_gain(&self, field_name: String) -> (f64, String) {
        self.elevation_gain_for_records(&self.0, field_name)
    }

    // given a bunch of records, calculate the elevation gain
    fn elevation_gain_for_records(
        &self,
        records: &Vec<FitDataRecord>,
        field_name: String,
    ) -> (f64, String) {
        let fields: Vec<&FitDataField> = records
            .iter()
            .filter(|r| r.kind() == MesgNum::Record)
            .flat_map(|r| r.fields().iter().filter(|field| field.name() == field_name))
            .collect();

        let count = fields.len();

        if count == 0 {
            return (0.0, String::from(""));
        }

        let units = fields.first().unwrap().units();

        let elevation_gain_sum = fields.windows(2).fold(0.0, |acc, window| {
            // find the field first
            let value1 = MyValue(window[1].value().clone()).as_f64();
            let value0 = MyValue(window[0].value().clone()).as_f64();

            match (value1, value0) {
                (Some(v1), Some(v0)) if v1 > v0 => acc + (v1 - v0),
                _ => acc,
            }
        });

        (elevation_gain_sum, String::from(units))
    }

    fn avg_for_records(&self, records: &Vec<FitDataRecord>, field_name: String) -> (f64, String) {
        // only get the record types
        let fields: Vec<&FitDataField> = records
            .iter()
            .filter(|r| r.kind() == MesgNum::Record)
            .flat_map(|r| r.fields().iter().filter(|field| field.name() == field_name))
            .collect();

        // do a map filter to only sum the possible values could be sumed
        // we only care about int, float values
        let sumable_values: Vec<f64> = fields
            .iter()
            .filter_map(|field| MyValue(field.value().clone()).as_f64())
            .collect();

        let sum: f64 = sumable_values.iter().sum();
        let count = sumable_values.len();

        if count == 0 {
            (0.0, String::from(""))
        } else {
            // we also need to return the unit
            let units = fields.first().unwrap().units();
            let avg_value = sum / count as f64;
            (avg_value, String::from(units))
        }
    }

    fn calculate_partition_indices(
        &self,
        partition_distance: f64,
        field_name: String,
    ) -> Vec<usize> {
        let records: Vec<&FitDataRecord> = self
            .0
            .iter()
            .filter(|r| r.kind() == MesgNum::Record)
            .collect();
        self.calculate_partition_indices_for_records(records, partition_distance, field_name)
    }

    fn calculate_partition_indices_for_records(
        &self,
        records: Vec<&FitDataRecord>,
        partition_distance: f64,
        field_name: String,
    ) -> Vec<usize> {
        let mut partition_indices = vec![0]; // always start include the start index
        let mut start_distance = 0.0;

        // let's loop
        for (index, record) in records.iter().enumerate().skip(1) {
            let fields: Vec<&FitDataField> = record
                .fields()
                .iter()
                .filter(|f| f.name() == field_name)
                .collect();

            let distance_field = fields
                .first()
                .and_then(|f| MyValue(f.value().clone()).as_f64());
            match distance_field {
                Some(distance_value) => {
                    if distance_value - start_distance >= partition_distance {
                        // found it
                        partition_indices.push(index);
                        start_distance = distance_value;
                    }
                }
                None => {}
            }
        }

        // now we have the whole array
        // if the last record is not there, add it
        if *partition_indices.last().unwrap() != records.len() - 1 {
            partition_indices.push(records.len() - 1);
        }

        partition_indices
    }
}

// recursive method to turn Fit value into magnus::Value
fn value_to_rb_value(value: &Value) -> magnus::Value {
    match value {
        Value::Timestamp(t) => t.timestamp().into_value(),
        Value::SInt8(i) => i.into_value(),
        Value::UInt8(u) => u.into_value(),
        Value::SInt16(i) => i.into_value(),
        Value::UInt16(u) => u.into_value(),
        Value::SInt32(i) => i.into_value(),
        Value::UInt32(u) => u.into_value(),
        Value::String(s) => s.clone().into_value(),
        Value::Float32(f) => f.into_value(),
        Value::Float64(f) => f.into_value(),
        Value::UInt8z(u) => u.into_value(),
        Value::UInt16z(u) => u.into_value(),
        Value::UInt32z(u) => u.into_value(),
        Value::Byte(b) => b.into_value(),
        Value::SInt64(i) => i.into_value(),
        Value::UInt64(u) => u.into_value(),
        Value::UInt64z(u) => u.into_value(),
        Value::Enum(e) => e.into_value(),
        Value::Array(arr) => {
            let rb_array = RArray::new();
            for value in arr {
                rb_array.push(value_to_rb_value(value)).unwrap();
            }
            rb_array.into_value()
        }
    }
}

// Turning FitDataRecord into a hash
fn get_fields_hash(record: &FitDataRecord) -> RHash {
    let hash = RHash::new();
    for field in record.fields() {
        let value = value_to_rb_value(field.value());
        let pair = RHash::new();
        pair.aset(Symbol::new("units"), field.units()).unwrap();
        pair.aset(Symbol::new("value"), value).unwrap();
        // here we add the stuff to the hash
        let field_name_symbol = Symbol::new(field.name());
        hash.aset(field_name_symbol, pair).unwrap();
    }

    hash
}

// Here we define two ruby classes
// RFitDataRecord and RFitDataField
fn define_ruby_classes(ruby: &Ruby) -> Result<(), magnus::Error> {
    // definie the the other one here
    let data_record_class = ruby.define_class("FitParseResult", ruby.class_object())?;
    data_record_class.define_method("records_hash", method!(FitParseResult::records_hash, 0))?;
    data_record_class.define_method("avg_for", method!(FitParseResult::avg_for, 1))?;
    data_record_class
        .define_method("elevation_gain", method!(FitParseResult::elevation_gain, 1))?;
    data_record_class.define_method(
        "calculate_partition_indices",
        method!(FitParseResult::calculate_partition_indices, 2),
    )?;

    Ok(())
}

fn parse_fit_file(file_path: String) -> Result<FitParseResult, magnus::Error> {
    let mut fp = File::open(file_path)
        .map_err(|e| Error::new(Ruby::get().unwrap().exception_io_error(), e.to_string()))?;
    let data = fitparser::from_reader(&mut fp).map_err(|e| {
        Error::new(
            Ruby::get().unwrap().exception_runtime_error(),
            e.to_string(),
        )
    })?;

    let result = FitParseResult(data);

    Ok(result)
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("FitKit")?;

    let _ = define_ruby_classes(ruby);
    module.define_singleton_method("parse_fit_file", function!(parse_fit_file, 1))?;

    Ok(())
}

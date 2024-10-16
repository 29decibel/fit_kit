use fitparser::{self, FitDataRecord, Value};
use itertools::Itertools;
use magnus::{function, prelude::*, Error, IntoValue, RArray, RHash, Ruby, Symbol};
use std::fs::File;

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

fn parse_fit_file(file_path: String) -> Result<RHash, magnus::Error> {
    let mut fp = File::open(file_path)
        .map_err(|e| Error::new(Ruby::get().unwrap().exception_io_error(), e.to_string()))?;
    let data = fitparser::from_reader(&mut fp).map_err(|e| {
        Error::new(
            Ruby::get().unwrap().exception_runtime_error(),
            e.to_string(),
        )
    })?;

    // now let's group by the record by kind
    let result_hash = RHash::new();
    for (kind, kind_records) in data
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

    Ok(result_hash)
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("FitKit")?;

    module.define_singleton_method("parse_fit_file", function!(parse_fit_file, 1))?;

    Ok(())
}

use fitparser::{self, FitDataRecord, Value};
use magnus::{function, method, prelude::*, Error, IntoValue, RArray, RHash, Ruby, Symbol};
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

///////////////////////// RFitDataRecord ///////////////////////////
#[magnus::wrap(class = "RFitDataRecord")]
struct RFitDataRecord(FitDataRecord);

impl RFitDataRecord {
    fn kind(&self) -> String {
        self.0.kind().to_string()
    }

    fn fields_hash(&self) -> RHash {
        let hash = RHash::new();
        for field in self.0.fields() {
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
}

// Here we define two ruby classes
// RFitDataRecord and RFitDataField
fn define_ruby_classes(ruby: &Ruby) -> Result<(), magnus::Error> {
    // definie the the other one here
    let data_record_class = ruby.define_class("RFitDataRecord", ruby.class_object())?;
    data_record_class.define_method("kind", method!(RFitDataRecord::kind, 0))?;
    data_record_class.define_method("fields_hash", method!(RFitDataRecord::fields_hash, 0))?;

    Ok(())
}

fn parse_fit_file(file_path: String) -> Result<RArray, magnus::Error> {
    let mut fp = File::open(file_path)
        .map_err(|e| Error::new(Ruby::get().unwrap().exception_io_error(), e.to_string()))?;
    let data = fitparser::from_reader(&mut fp).map_err(|e| {
        Error::new(
            Ruby::get().unwrap().exception_runtime_error(),
            e.to_string(),
        )
    })?;

    // finally we have the result array of record
    let array = RArray::new();
    for record in data {
        array.push(RFitDataRecord(record)).unwrap();
    }

    Ok(array)
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("FitKit")?;
    let _ = define_ruby_classes(&ruby);

    module.define_singleton_method("parse_fit_file", function!(parse_fit_file, 1))?;

    Ok(())
}

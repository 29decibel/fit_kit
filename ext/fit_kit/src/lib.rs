use fitparser::{self, FitDataField, FitDataRecord, Value};
use magnus::{function, method, prelude::*, Error, IntoValue, RArray, Ruby};
use std::fs::File;

///////////////////////// RFitDataField ///////////////////////////
// define a wrapper ruby class for FitDataField
#[magnus::wrap(class = "RFitDataField")]
struct RFitDataField(FitDataField);

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

impl RFitDataField {
    fn name(&self) -> String {
        self.0.name().to_string()
    }

    fn value(&self) -> magnus::Value {
        value_to_rb_value(self.0.value())
    }
}

///////////////////////// RFitDataRecord ///////////////////////////
#[magnus::wrap(class = "RFitDataRecord")]
struct RFitDataRecord(FitDataRecord);

impl RFitDataRecord {
    fn kind(&self) -> String {
        self.0.kind().to_string()
    }

    fn fields(&self) -> RArray {
        let array = RArray::new();
        for field in self.0.fields() {
            array.push(RFitDataField(field.clone())).unwrap();
        }
        array
    }
}

// Here we define two ruby classes
// RFitDataRecord and RFitDataField
fn define_ruby_classes(ruby: &Ruby) -> Result<(), magnus::Error> {
    let class = ruby.define_class("RFitDataField", ruby.class_object())?;

    // define bunch of methods
    class.define_method("name", method!(RFitDataField::name, 0))?;
    class.define_method("value", method!(RFitDataField::value, 0))?;

    // definie the the other one here
    let data_record_class = ruby.define_class("RFitDataRecord", ruby.class_object())?;
    data_record_class.define_method("kind", method!(RFitDataRecord::kind, 0))?;
    data_record_class.define_method("fields", method!(RFitDataRecord::fields, 0))?;

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

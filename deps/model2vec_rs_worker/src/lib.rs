use anyhow::Result;
use jlrs::{error::JlrsError, prelude::*};
use model2vec_rs::model::StaticModel;
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    slice,
};

struct State {
    model: StaticModel,
    query: Vec<f32>,
}

fn cosine(left: &[f32], right: &[f32]) -> f64 {
    let mut dot = 0.0;
    let mut leftnorm = 0.0;
    let mut rightnorm = 0.0;

    for (leftvalue, rightvalue) in left.iter().zip(right.iter()) {
        let first = *leftvalue as f64;
        let second = *rightvalue as f64;
        dot += first * second;
        leftnorm += first * first;
        rightnorm += second * second;
    }

    dot / (leftnorm.sqrt() * rightnorm.sqrt() + f64::EPSILON)
}

fn protect<T>(f: impl FnOnce() -> JlrsResult<T>) -> JlrsResult<T> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(value) => value,
        Err(_) => Err(Box::new(JlrsError::exception("panic in model2vec_rs_worker"))),
    }
}

fn failure(error: impl ToString) -> Box<JlrsError> {
    Box::new(JlrsError::exception(error.to_string()))
}

fn open(model: &str, query: &str) -> Result<usize> {
    let model = StaticModel::from_pretrained(model, None, None, None)?;
    let query = model.encode(&[query.to_owned()]).remove(0);
    Ok(Box::into_raw(Box::new(State { model, query })) as usize)
}

fn close(handle: usize) -> Nothing {
    if handle != 0 {
        unsafe {
            drop(Box::from_raw(handle as *mut State));
        }
    }

    Nothing
}

fn score(handle: usize, textpointers: &[usize], textlengths: &[usize]) -> Result<Vec<f64>> {
    let state = unsafe { &*(handle as *const State) };
    let texts = textpointers
        .iter()
        .zip(textlengths.iter())
        .map(|(&pointer, &length)| unsafe {
            std::str::from_utf8_unchecked(slice::from_raw_parts(pointer as *const u8, length)).to_owned()
        })
        .collect::<Vec<_>>();
    let embeddings = state.model.encode_with_args(&texts, Some(512), texts.len());
    let mut scores = Vec::with_capacity(embeddings.len());

    for embedding in embeddings.iter() {
        scores.push(1.0 - cosine(&state.query, embedding));
    }

    Ok(scores)
}

fn openstate(model: JuliaString, query: JuliaString) -> JlrsResult<usize> {
    protect(|| Ok(open(model.as_str()?, query.as_str()?).map_err(failure)?))
}

fn closestate(handle: usize) -> Nothing {
    close(handle)
}

fn scorebatch(
    handle: usize,
    textpointers: TypedVector<usize>,
    textlengths: TypedVector<usize>,
    scores: TypedVector<f64>,
) -> JlrsResult<Nothing> {
    protect(|| {
        let textpointers = textpointers.track_shared()?;
        let textlengths = textlengths.track_shared()?;
        let mut scores = scores.track_exclusive()?;
        let textpointers = textpointers.bits_data();
        let textlengths = textlengths.bits_data();
        let mut scores = unsafe { scores.bits_data_mut() };
        let textpointers = textpointers.as_slice();
        let textlengths = textlengths.as_slice();
        let values = score(handle, textpointers, textlengths).map_err(failure)?;

        for (index, value) in values.into_iter().enumerate() {
            scores[index] = value;
        }

        Ok(Nothing)
    })
}

julia_module! {
    become model2vec_rs_worker_init_fn;
    fn openstate(model: JuliaString, query: JuliaString) -> JlrsResult<usize>;
    fn closestate(handle: usize) -> Nothing;
    fn scorebatch(handle: usize, textpointers: TypedVector<usize>, textlengths: TypedVector<usize>, scores: TypedVector<f64>) -> JlrsResult<Nothing> as scorebatch!;
}

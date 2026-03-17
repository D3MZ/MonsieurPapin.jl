use aho_corasick::{AhoCorasick, AhoCorasickBuilder};
use anyhow::Result;
use jlrs::{error::JlrsError, prelude::*};
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    slice,
};

mod model;
use model::StaticModel;

struct State {
    model: StaticModel,
    query: Vec<f32>,
}

struct ACState {
    ac: AhoCorasick,
    weights: Option<Vec<f64>>,
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
        Err(_) => Err(Box::new(JlrsError::exception(
            "panic in model2vec_rs_worker",
        ))),
    }
}

fn failure(error: impl ToString) -> Box<JlrsError> {
    Box::new(JlrsError::exception(error.to_string()))
}

fn open(model: &str, query: &str) -> Result<usize> {
    let model = StaticModel::from_pretrained(model, None, None, None)?;
    let query = model.encode(&[query.to_owned()])?.remove(0);
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
        .map(|(&pointer, &length)| {
            let bytes = unsafe { slice::from_raw_parts(pointer as *const u8, length) };
            String::from_utf8_lossy(bytes).into_owned()
        })
        .collect::<Vec<_>>();
    let embeddings = state.model.encode(&texts)?;
    Ok(embeddings
        .into_iter()
        .map(|embedding| 1.0 - cosine(&state.query, &embedding))
        .collect())
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

fn build_aho_corasick(patterns: JuliaString) -> JlrsResult<usize> {
    protect(|| {
        let patterns_str = patterns.as_str()?;
        let patterns_vec: Vec<String> = patterns_str.split('\x1F').map(|s| s.to_owned()).collect();
        let ac = AhoCorasickBuilder::new()
            .ascii_case_insensitive(true)
            .build(patterns_vec)
            .map_err(failure)?;
        Ok(Box::into_raw(Box::new(ACState { ac, weights: None })) as usize)
    })
}

fn build_weighted_aho_corasick(
    patterns: JuliaString,
    weights: TypedVector<f64>,
) -> JlrsResult<usize> {
    protect(|| {
        let patterns_str = patterns.as_str()?;
        let patterns_vec: Vec<String> = patterns_str.split('\x1F').map(|s| s.to_owned()).collect();
        let weights = weights.track_shared()?;
        let values = weights.bits_data().as_slice().to_vec();
        let ac = AhoCorasickBuilder::new()
            .ascii_case_insensitive(true)
            .build(patterns_vec)
            .map_err(failure)?;
        Ok(Box::into_raw(Box::new(ACState { ac, weights: Some(values) })) as usize)
    })
}

fn match_aho_corasick(handle: usize, pointer: usize, length: usize) -> JlrsResult<u32> {
    protect(|| {
        let state = unsafe { &*(handle as *const ACState) };
        let haystack = unsafe { slice::from_raw_parts(pointer as *const u8, length) };
        Ok(state.ac.find_iter(haystack).count() as u32)
    })
}

fn match_weighted_aho_corasick(
    handle: usize,
    pointer: usize,
    length: usize,
) -> JlrsResult<f64> {
    protect(|| {
        let state = unsafe { &*(handle as *const ACState) };
        let haystack = unsafe { slice::from_raw_parts(pointer as *const u8, length) };
        let weights = state.weights.as_ref().unwrap();
        Ok(state
            .ac
            .find_iter(haystack)
            .map(|m| weights[m.pattern().as_usize()])
            .sum())
    })
}

fn close_aho_corasick(handle: usize) -> Nothing {
    if handle != 0 {
        unsafe {
            drop(Box::from_raw(handle as *mut ACState));
        }
    }
    Nothing
}

julia_module! {
    become model2vec_rs_worker_init_fn;
    fn openstate(model: JuliaString, query: JuliaString) -> JlrsResult<usize>;
    fn closestate(handle: usize) -> Nothing;
    fn scorebatch(handle: usize, textpointers: TypedVector<usize>, textlengths: TypedVector<usize>, scores: TypedVector<f64>) -> JlrsResult<Nothing> as scorebatch!;
    fn build_aho_corasick(patterns: JuliaString) -> JlrsResult<usize>;
    fn build_weighted_aho_corasick(patterns: JuliaString, weights: TypedVector<f64>) -> JlrsResult<usize>;
    fn match_aho_corasick(handle: usize, pointer: usize, length: usize) -> JlrsResult<u32>;
    fn match_weighted_aho_corasick(handle: usize, pointer: usize, length: usize) -> JlrsResult<f64>;
    fn close_aho_corasick(handle: usize) -> Nothing;
}

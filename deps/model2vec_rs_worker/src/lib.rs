use aho_corasick::{AhoCorasick, AhoCorasickBuilder};
use anyhow::Result;
use daachorse::DoubleArrayAhoCorasick;
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

struct ACState {
    ac: AhoCorasick,
}

struct DAACState {
    daac: DoubleArrayAhoCorasick<u32>,
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

fn build_aho_corasick(patterns: JuliaString) -> JlrsResult<usize> {
    protect(|| {
        let patterns_str = patterns.as_str()?;
        let patterns_vec: Vec<String> = patterns_str.split('\x1F').map(|s| s.to_owned()).collect();
        let ac = AhoCorasickBuilder::new()
            .ascii_case_insensitive(true)
            .build(patterns_vec)
            .map_err(failure)?;
        Ok(Box::into_raw(Box::new(ACState { ac })) as usize)
    })
}

fn build_daachorse(patterns: JuliaString) -> JlrsResult<usize> {
    protect(|| {
        let patterns_str = patterns.as_str()?;
        let patterns_vec: Vec<String> = patterns_str.split('\x1F').map(|s| s.to_owned()).collect();
        let daac = DoubleArrayAhoCorasick::new(patterns_vec).map_err(failure)?;
        Ok(Box::into_raw(Box::new(DAACState { daac })) as usize)
    })
}

fn match_aho_corasick(handle: usize, pointer: usize, length: usize) -> JlrsResult<bool> {
    protect(|| {
        let state = unsafe { &*(handle as *const ACState) };
        let haystack = unsafe { slice::from_raw_parts(pointer as *const u8, length) };
        Ok(state.ac.find(haystack).is_some())
    })
}

fn match_daachorse(handle: usize, pointer: usize, length: usize) -> JlrsResult<bool> {
    protect(|| {
        let state = unsafe { &*(handle as *const DAACState) };
        let haystack = unsafe { slice::from_raw_parts(pointer as *const u8, length) };
        Ok(state.daac.find_iter(haystack).next().is_some())
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

fn close_daachorse(handle: usize) -> Nothing {
    if handle != 0 {
        unsafe {
            drop(Box::from_raw(handle as *mut DAACState));
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
    fn build_daachorse(patterns: JuliaString) -> JlrsResult<usize>;
    fn match_aho_corasick(handle: usize, pointer: usize, length: usize) -> JlrsResult<bool>;
    fn match_daachorse(handle: usize, pointer: usize, length: usize) -> JlrsResult<bool>;
    fn close_aho_corasick(handle: usize) -> Nothing;
    fn close_daachorse(handle: usize) -> Nothing;
}

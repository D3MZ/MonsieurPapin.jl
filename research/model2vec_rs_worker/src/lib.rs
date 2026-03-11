use model2vec_rs::model::StaticModel;
use std::{panic::{catch_unwind, AssertUnwindSafe}, ptr, slice};

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

unsafe fn view(pointer: *const u8, length: usize) -> &'static str {
    unsafe { std::str::from_utf8_unchecked(slice::from_raw_parts(pointer, length)) }
}

unsafe fn text(pointer: *const u8, length: usize) -> String {
    unsafe { String::from_utf8_lossy(slice::from_raw_parts(pointer, length)).into_owned() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn model2vec_open(
    modelpointer: *const u8,
    modellength: usize,
    querypointer: *const u8,
    querylength: usize,
) -> *mut std::ffi::c_void {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(model) = StaticModel::from_pretrained(unsafe { view(modelpointer, modellength) }, None, None, None).ok() else {
            return ptr::null_mut();
        };
        let query = model
            .encode(&[unsafe { text(querypointer, querylength) }])
            .into_iter()
            .next()
            .unwrap_or_default();
        Box::into_raw(Box::new(State { model, query })) as *mut std::ffi::c_void
    }))
    .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn model2vec_close(state: *mut std::ffi::c_void) {
    if state.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(state as *mut State));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn model2vec_score_batch(
    state: *const std::ffi::c_void,
    textpointers: *const *const u8,
    textlengths: *const usize,
    count: usize,
    scores: *mut f64,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if state.is_null() || count == 0 {
            return 0;
        }

        let state = unsafe { &*(state as *const State) };
        let textpointers = unsafe { slice::from_raw_parts(textpointers, count) };
        let textlengths = unsafe { slice::from_raw_parts(textlengths, count) };
        let scores = unsafe { slice::from_raw_parts_mut(scores, count) };
        let texts = textpointers
            .iter()
            .zip(textlengths.iter())
            .map(|(&pointer, &length)| unsafe { text(pointer, length) })
            .collect::<Vec<_>>();
        let embeddings = state.model.encode_with_args(&texts, Some(512), count);

        for (score, embedding) in scores.iter_mut().zip(embeddings.iter()) {
            *score = 1.0 - cosine(&state.query, embedding);
        }

        0
    }))
    .unwrap_or(-1)
}

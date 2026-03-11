use anyhow::{anyhow, Context, Result};
use half::f16;
use hf_hub::api::sync::Api;
use ndarray::Array2;
use safetensors::{tensor::Dtype, SafeTensors};
use serde_json::{json, Value};
use std::{
    collections::BTreeSet,
    env, fs,
    io::{self, BufRead, BufReader, Read},
    path::{Path, PathBuf},
    sync::Mutex,
    time::Instant,
};
use tokenizers::{
    parallelism::{current_num_threads, get_parallelism, has_parallelism_been_used, MaybeParallelIterator},
    Tokenizer,
};

struct DiagnosticModel {
    tokenizer: Tokenizer,
    embeddings: Array2<f32>,
    weights: Option<Vec<f32>>,
    mapping: Option<Vec<usize>>,
    normalize: bool,
    median: usize,
    unknown: Option<usize>,
}

fn readcount(reader: &mut BufReader<io::StdinLock<'_>>, line: &mut String) -> Result<Option<usize>> {
    line.clear();
    let read = reader.read_line(line).context("missing batch header")?;
    if read == 0 {
        return Ok(None);
    }
    let value = line.trim();
    if value.is_empty() {
        return Ok(None);
    }
    Ok(Some(value.parse()?))
}

fn readtexts(reader: &mut BufReader<io::StdinLock<'_>>, count: usize, line: &mut String) -> Result<Vec<String>> {
    let mut texts = Vec::with_capacity(count);
    for _ in 0..count {
        line.clear();
        reader.read_line(line).context("missing content length")?;
        let length = line.trim().parse()?;
        let mut text = vec![0; length];
        reader.read_exact(&mut text)?;
        texts.push(String::from_utf8_lossy(&text).into_owned());
    }
    Ok(texts)
}

fn locate(model: &str) -> Result<(PathBuf, PathBuf, PathBuf)> {
    let root = Path::new(model);
    if root.exists() {
        let tokenizer = root.join("tokenizer.json");
        let tensors = root.join("model.safetensors");
        let config = root.join("config.json");
        (!tokenizer.exists() || !tensors.exists() || !config.exists())
            .then(|| anyhow!("model path missing tokenizer.json, model.safetensors, or config.json"))
            .map_or(Ok((tokenizer, tensors, config)), Err)
    } else {
        let api = Api::new().context("hf-hub api")?;
        let repo = api.model(model.to_string());
        Ok((
            repo.get("tokenizer.json")?,
            repo.get("model.safetensors")?,
            repo.get("config.json")?,
        ))
    }
}

fn floats(tensor: safetensors::tensor::TensorView<'_>) -> Result<Vec<f32>> {
    let bytes = tensor.data();
    match tensor.dtype() {
        Dtype::F32 => Ok(bytes
            .chunks_exact(4)
            .map(|chunk| f32::from_le_bytes(chunk.try_into().unwrap()))
            .collect()),
        Dtype::F16 => Ok(bytes
            .chunks_exact(2)
            .map(|chunk| f16::from_le_bytes(chunk.try_into().unwrap()).to_f32())
            .collect()),
        Dtype::I8 => Ok(bytes.iter().map(|&byte| f32::from(byte as i8)).collect()),
        dtype => Err(anyhow!("unsupported embedding dtype {dtype:?}")),
    }
}

fn weights(tensors: &SafeTensors<'_>) -> Result<Option<Vec<f32>>> {
    let Ok(tensor) = tensors.tensor("weights") else {
        return Ok(None);
    };
    let bytes = tensor.data();
    let values = match tensor.dtype() {
        Dtype::F64 => bytes
            .chunks_exact(8)
            .map(|chunk| f64::from_le_bytes(chunk.try_into().unwrap()) as f32)
            .collect(),
        Dtype::F32 => bytes
            .chunks_exact(4)
            .map(|chunk| f32::from_le_bytes(chunk.try_into().unwrap()))
            .collect(),
        Dtype::F16 => bytes
            .chunks_exact(2)
            .map(|chunk| f16::from_le_bytes(chunk.try_into().unwrap()).to_f32())
            .collect(),
        dtype => return Err(anyhow!("unsupported weights dtype {dtype:?}")),
    };
    Ok(Some(values))
}

fn mapping(tensors: &SafeTensors<'_>) -> Option<Vec<usize>> {
    let Ok(tensor) = tensors.tensor("mapping") else {
        return None;
    };
    Some(
        tensor
            .data()
            .chunks_exact(4)
            .map(|chunk| i32::from_le_bytes(chunk.try_into().unwrap()) as usize)
            .collect(),
    )
}

fn load(model: &str) -> Result<DiagnosticModel> {
    let (tokenizerpath, tensorpath, configpath) = locate(model)?;
    let tokenizer = Tokenizer::from_file(&tokenizerpath).map_err(|error| anyhow!("tokenizer load failed: {error}"))?;
    let mut lengths = tokenizer.get_vocab(false).keys().map(|token| token.len()).collect::<Vec<_>>();
    lengths.sort_unstable();
    let median = lengths.get(lengths.len() / 2).copied().unwrap_or(1);

    let config = serde_json::from_reader::<_, Value>(fs::File::open(configpath).context("open config")?).context("parse config")?;
    let normalize = config.get("normalize").and_then(Value::as_bool).unwrap_or(true);

    let spec = serde_json::from_str::<Value>(&tokenizer.to_string(false).map_err(|error| anyhow!("tokenizer stringify failed: {error}"))?)?;
    let unknown = spec
        .get("model")
        .and_then(|model| model.get("unk_token"))
        .and_then(Value::as_str)
        .and_then(|token| tokenizer.token_to_id(token))
        .map(|id| id as usize);

    let bytes = fs::read(tensorpath).context("read tensors")?;
    let tensors = SafeTensors::deserialize(&bytes).context("parse tensors")?;
    let tensor = tensors.tensor("embeddings").or_else(|_| tensors.tensor("0")).context("embeddings tensor")?;
    let [rows, cols]: [usize; 2] = tensor.shape().try_into().context("embedding tensor is not 2-D")?;
    let embeddings = Array2::from_shape_vec((rows, cols), floats(tensor)?).context("build embeddings")?;

    Ok(DiagnosticModel {
        tokenizer,
        embeddings,
        weights: weights(&tensors)?,
        mapping: mapping(&tensors),
        normalize,
        median,
        unknown,
    })
}

fn truncate(text: &str, max: usize, median: usize) -> &str {
    let chars = max.saturating_mul(median);
    match text.char_indices().nth(chars) {
        Some((index, _)) => &text[..index],
        None => text,
    }
}

fn collectset(set: &Mutex<BTreeSet<String>>) -> Vec<String> {
    set.lock().unwrap().iter().cloned().collect()
}

fn pool(model: &DiagnosticModel, ids: Vec<u32>) -> Vec<f32> {
    let width = model.embeddings.ncols();
    let mut sum = vec![0.0; width];
    let mut count = 0usize;

    for id in ids {
        let token = id as usize;
        let row = model.mapping.as_ref().and_then(|mapping| mapping.get(token)).copied().unwrap_or(token);
        let scale = model.weights.as_ref().and_then(|weights| weights.get(token)).copied().unwrap_or(1.0);
        let embedding = model.embeddings.row(row);
        for (index, value) in embedding.iter().enumerate() {
            sum[index] += value * scale;
        }
        count += 1;
    }

    let denominator = count.max(1) as f32;
    sum.iter_mut().for_each(|value| *value /= denominator);

    if model.normalize {
        let norm = sum.iter().map(|value| value * value).sum::<f32>().sqrt().max(1e-12);
        sum.iter_mut().for_each(|value| *value /= norm);
    }

    sum
}

fn encode(model: &DiagnosticModel, texts: &[String], max: usize) -> Result<Value> {
    let inputs = texts.iter().map(|text| truncate(text, max, model.median)).collect::<Vec<_>>();
    let tokenthreads = Mutex::new(BTreeSet::new());
    let tokenstart = Instant::now();
    let encodings = inputs
        .into_maybe_par_iter()
        .map(|text| {
            tokenthreads.lock().unwrap().insert(format!("{:?}", std::thread::current().id()));
            model.tokenizer.encode_fast(text, false)
        })
        .collect::<tokenizers::Result<Vec<_>>>()
        .map_err(|error| anyhow!("tokenize failed: {error}"))?;
    let tokenelapsed = tokenstart.elapsed();

    let poolthreads = Mutex::new(BTreeSet::new());
    let poolstart = Instant::now();
    let dimensions = encodings
        .into_iter()
        .map(|encoding| {
            poolthreads.lock().unwrap().insert(format!("{:?}", std::thread::current().id()));
            let mut ids = encoding.get_ids().to_vec();
            if let Some(unknown) = model.unknown {
                ids.retain(|&id| id as usize != unknown);
            }
            ids.truncate(max);
            pool(model, ids)
        })
        .collect::<Vec<_>>();
    let poolelapsed = poolstart.elapsed();

    Ok(json!({
        "rayon_threads": current_num_threads(),
        "tokenizers_parallelism": get_parallelism(),
        "parallelism_used": has_parallelism_been_used(),
        "texts": texts.len(),
        "dimensions": dimensions.len(),
        "tokenize_ms": tokenelapsed.as_secs_f64() * 1000.0,
        "pool_ms": poolelapsed.as_secs_f64() * 1000.0,
        "token_threads": collectset(&tokenthreads),
        "pool_threads": collectset(&poolthreads),
    }))
}

fn main() -> Result<()> {
    let model = load(&env::var("MONSIEURPAPIN_MODEL")?)?;
    let stdin = io::stdin();
    let mut reader = BufReader::new(stdin.lock());
    let mut line = String::new();
    let Some(count) = readcount(&mut reader, &mut line)? else {
        return Ok(());
    };
    let texts = readtexts(&mut reader, count, &mut line)?;
    println!("{}", encode(&model, &texts, 512)?);
    Ok(())
}

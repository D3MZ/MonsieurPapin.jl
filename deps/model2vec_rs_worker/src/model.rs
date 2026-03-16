use anyhow::{Context, Result, anyhow};
use half::f16;
use hf_hub::api::sync::Api;
use ndarray::Array2;
use safetensors::{SafeTensors, tensor::Dtype};
use serde_json::Value;
use std::{env, fs, path::Path};
use tokenizers::Tokenizer;

pub struct StaticModel {
    tokenizer: Tokenizer,
    embeddings: Array2<f32>,
    weights: Option<Vec<f32>>,
    mapping: Option<Vec<usize>>,
    normalize: bool,
    median: usize,
    unknown: Option<usize>,
}

impl StaticModel {
    pub fn from_pretrained<P: AsRef<Path>>(
        repo_or_path: P,
        token: Option<&str>,
        normalize: Option<bool>,
        subfolder: Option<&str>,
    ) -> Result<Self> {
        if let Some(value) = token {
            unsafe { env::set_var("HF_HUB_TOKEN", value) };
        }

        let (tokenizerpath, tensorpath, configpath) = {
            let base = repo_or_path.as_ref();
            if base.exists() {
                let folder = subfolder
                    .map(|value| base.join(value))
                    .unwrap_or_else(|| base.to_path_buf());
                let tokenizer = folder.join("tokenizer.json");
                let tensors = folder.join("model.safetensors");
                let config = folder.join("config.json");
                if !tokenizer.exists() || !tensors.exists() || !config.exists() {
                    return Err(anyhow!(
                        "local path {folder:?} missing tokenizer / model / config"
                    ));
                }
                (tokenizer, tensors, config)
            } else {
                let api = Api::new().context("hf-hub API init failed")?;
                let repo = api.model(base.to_string_lossy().into_owned());
                let prefix = subfolder
                    .map(|value| format!("{value}/"))
                    .unwrap_or_default();
                (
                    repo.get(&format!("{prefix}tokenizer.json"))?,
                    repo.get(&format!("{prefix}model.safetensors"))?,
                    repo.get(&format!("{prefix}config.json"))?,
                )
            }
        };

        let tokenizer = Tokenizer::from_file(&tokenizerpath)
            .map_err(|error| anyhow!("failed to load tokenizer: {error}"))?;
        let mut lengths = tokenizer
            .get_vocab(false)
            .keys()
            .map(|token| token.len())
            .collect::<Vec<_>>();
        lengths.sort_unstable();
        let median = lengths.get(lengths.len() / 2).copied().unwrap_or(1);

        let config = serde_json::from_reader::<_, Value>(
            fs::File::open(configpath).context("failed to read config.json")?,
        )
        .context("failed to parse config.json")?;
        let normalize = normalize.unwrap_or(
            config
                .get("normalize")
                .and_then(Value::as_bool)
                .unwrap_or(true),
        );

        let specification = serde_json::from_str::<Value>(
            &tokenizer
                .to_string(false)
                .map_err(|error| anyhow!("tokenizer -> JSON failed: {error}"))?,
        )?;
        let unknown = specification
            .get("model")
            .and_then(|model| model.get("unk_token"))
            .and_then(Value::as_str)
            .and_then(|token| tokenizer.token_to_id(token))
            .map(|id| id as usize);

        let bytes = fs::read(tensorpath).context("failed to read model.safetensors")?;
        let tensors = SafeTensors::deserialize(&bytes).context("failed to parse safetensors")?;
        let tensor = tensors
            .tensor("embeddings")
            .or_else(|_| tensors.tensor("0"))
            .context("embeddings tensor not found")?;
        let [rows, cols]: [usize; 2] = tensor
            .shape()
            .try_into()
            .context("embedding tensor is not 2-D")?;
        let embeddings = Array2::from_shape_vec((rows, cols), floats(tensor)?)
            .context("failed to build embeddings array")?;

        Ok(Self {
            tokenizer,
            embeddings,
            weights: weights(&tensors)?,
            mapping: mapping(&tensors),
            normalize,
            median,
            unknown,
        })
    }

    pub fn encode(&self, sentences: &[String]) -> Result<Vec<Vec<f32>>> {
        self.encode_with_args(sentences, Some(512), 1024)
    }

    pub fn encode_with_args(
        &self,
        sentences: &[String],
        max_length: Option<usize>,
        batch_size: usize,
    ) -> Result<Vec<Vec<f32>>> {
        let mut embeddings = Vec::with_capacity(sentences.len());

        for batch in sentences.chunks(batch_size) {
            let inputs = batch
                .iter()
                .map(|text| {
                    max_length
                        .map(|max| truncate(text, max, self.median))
                        .unwrap_or(text.as_str())
                })
                .collect::<Vec<_>>();
            let encodings = self
                .tokenizer
                .encode_batch(inputs, false)
                .map_err(|error| anyhow!("tokenization failed: {error}"))?;

            for encoding in encodings {
                let mut ids = encoding.get_ids().to_vec();
                if let Some(unknown) = self.unknown {
                    ids.retain(|&id| id as usize != unknown);
                }
                if let Some(max) = max_length {
                    ids.truncate(max);
                }
                embeddings.push(self.pool(ids));
            }
        }

        Ok(embeddings)
    }

    fn pool(&self, ids: Vec<u32>) -> Vec<f32> {
        let width = self.embeddings.ncols();
        let mut sum = vec![0.0; width];
        let mut count = 0usize;

        for id in ids {
            let token = id as usize;
            let row = self
                .mapping
                .as_ref()
                .and_then(|mapping| mapping.get(token))
                .copied()
                .unwrap_or(token);
            let scale = self
                .weights
                .as_ref()
                .and_then(|weights| weights.get(token))
                .copied()
                .unwrap_or(1.0);
            let embedding = self.embeddings.row(row);

            for (index, value) in embedding.iter().enumerate() {
                sum[index] += value * scale;
            }

            count += 1;
        }

        let denominator = count.max(1) as f32;
        sum.iter_mut().for_each(|value| *value /= denominator);

        if self.normalize {
            let norm = sum
                .iter()
                .map(|value| value * value)
                .sum::<f32>()
                .sqrt()
                .max(1e-12);
            sum.iter_mut().for_each(|value| *value /= norm);
        }

        sum
    }
}

fn truncate(text: &str, max: usize, median: usize) -> &str {
    let chars = max.saturating_mul(median);
    match text.char_indices().nth(chars) {
        Some((index, _)) => &text[..index],
        None => text,
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

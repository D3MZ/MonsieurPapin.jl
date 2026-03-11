use anyhow::{Context, Result};
use model2vec_rs::model::StaticModel;
use std::env;
use std::io::{self, BufRead, BufReader, Read, Write};

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

fn readtexts(reader: &mut BufReader<io::StdinLock<'_>>, count: usize, line: &mut String) -> Result<Vec<Vec<u8>>> {
    let mut texts = Vec::with_capacity(count);
    for _ in 0..count {
        line.clear();
        reader.read_line(line).context("missing content length")?;
        let length = line.trim().parse()?;
        let mut text = vec![0; length];
        reader.read_exact(&mut text)?;
        texts.push(text);
    }
    Ok(texts)
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

fn main() -> Result<()> {
    let modelname = env::var("MONSIEURPAPIN_MODEL")?;
    let query = env::var("MONSIEURPAPIN_QUERY")?;
    let model = StaticModel::from_pretrained(&modelname, None, None, None)?;
    let queryembedding = model.encode(&[query]).remove(0);

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = stdout.lock();
    let mut line = String::new();

    loop {
        let Some(batch) = readcount(&mut reader, &mut line)? else {
            return Ok(());
        };
        let texts = readtexts(&mut reader, batch, &mut line)?
            .into_iter()
            .map(|text| String::from_utf8_lossy(&text).into_owned())
            .collect::<Vec<_>>();
        let scores = model
            .encode(&texts)
            .iter()
            .map(|row| (1.0 - cosine(&queryembedding, row)).to_string())
            .collect::<Vec<_>>();
        writeln!(writer, "{}", scores.join("\t"))?;
        writer.flush()?;
    }
}

# Evaluation scripts
Due to the large number of files that need to be processed the main evaluation is split into three steps
- generation of files with statistics (parallel) - `generate_stats.jl`
- collection of previously generated files into one cached dataframe (parallel) - `collect_stats.jl`
- printing of summary tables - `evaluate_performance.jl`

The first two steps can be run as a batch job by running `sbatch --output ${HOME}/logs/eval-%J.out run_eval.sh {arg}` script with `images|tabular` argument, specifying which datasets to take into account. By default this won't rewrite any precomputed files with the exception of the cached DataFrame in the second step. 

```
    julia --threads 16 --project ./generate_stats.jl experiments/images evaluation/images 
```
will collect all the experiment files from `experiments/images` data folder and generates the statistics files into the same structed folders but with different data prefix `evaluation/images`. Unless `-f` flag is added the script will ignore experiment files for which the statistics already exist in `evaluation/images`.

```
    julia --threads 16 --project ./collect_stats.jl  evaluation/images evaluation/images_eval.bson -f
```
will collect all the statistics files from `evaluation/images` data folder and store them into one dataframe `images_eval.bson`
in the `evaluation` data folder.

The third step is intended to be run in more interactive manner as it allows multiple summary options.
- loading `evaluation/images_eval.bson` cache, using `val_auc` for sorting models and `tst_auc` for final ranking, storing the rank table as `html` page in data prefixed folder given by `--output-prefix`
```
    julia --project ./evaluate_performance.jl \
                        evaluation/images_eval.bson \
                        --output-prefix evaluation/images_eval \
                        --criterion-metric val_auc \
                        --rank-metric tst_auc \
                        --backend html 
```

- loading `evaluation/images_eval.bson` cache, using `val_pat_10` for sorting models and `tst_pat_10` for final ranking, printing the result to stdout, additionally `--best-params` will store metadata for best models of each type into separate CSVs
```
    julia --project ./evaluate_performance.jl \
                        evaluation/images_eval.bson \
                        --criterion-metric val_pat_10 \
                        --rank-metric tst_pat_10 \
                        --backend txt \
                        --verbose \
                        --best-params
```

- loading `evaluation/images_eval.bson` cache, using `val_pat_x` with increasing `x` for sorting models and `tst_pat_10` for final ranking, printing the ranking given percentage of labeled samples in the validation to txt file in data prefixed folder given by `--output-prefix`
```
    julia --project ./evaluate_performance.jl \
                        evaluation/images_eval.bson \
                        --output-prefix evaluation/images_eval \
                        --rank-metric tst_pat_10 \
                        --proportional
```

Some combinations of parameters don't make sense, such as running with `--best-params` while also using `--proportional`. Furthermore the tex(latex) output does not escape underscores and therefore cannot be parsed sometimes. The code scaling to multiple threads does not work optimally, but it is encouraged to use 32 threads when processing more than 50k files.
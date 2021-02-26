using Zygote

function lkl_quantile(transformation, batch, percentage=(0.0, 1.0))
    score = logpdf(transformation, batch)
    n = nobs(batch)
    l, r = percentage
    if l <= 0.0
        lq = 1
    else
        lq = Int(ceil(l*n))
    end
    if r >= 1.0
        rq = n
    else
        rq = Int(ceil(r*n))
    end
    perms = sortperm(score)
    indxs = perms[lq:rq]
    return batch[:, indxs]
end
Zygote.@nograd lkl_quantile

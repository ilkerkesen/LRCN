# loss function
function loss(w, s, visual, captions; o=Dict())
    finetune = get(o, :fintune, false)
    if finetune
        visual = vgg19(w[1:end-6], KnetArray(visual); o=o)
        visual = transpose(visual)
    else
        atype = typeof(AutoGrad.getval(w[1]))
        visual = convert(atype, visual)
    end
    return decoder(w[end-5:end], s, visual, captions; dropouts=dropouts)
end

# loss gradient
lossgradient = grad(loss)

# loss function for decoder network
function decoder(w, s, vis, seq; o=Dict(), values=[])
    total, count = 0, 0
    atype = typeof(AutoGrad.getval(w[1]))

    # set dropouts
    membdrop = get(dropouts, :membdrop, 0.0)
    vembdrop = get(dropouts, :vembdrop, 0.0)
    wembdrop = get(dropouts, :wembdrop, 0.0)
    softdrop = get(dropouts, :softdrop, 0.0)
    fc7drop  = get(dropouts, :fc7drop, 0.0)

    text = convert(atype, seq[1])
    for i = 1:length(seq)-1
        visual = dropout(vis, fc7drop) * w[5]
        text = text * w[6]
        text = dropout(text, wembdrop)
        x = hcat(dropout(visual, vembdrop), text)
        (s[1], s[2]) = lstm(w[1], w[2], s[1], s[2], x)
        ht = s[1]
        ht = dropout(ht, softdrop)
        ypred = logp(ht * w[3] .+ w[4], 2)
        ygold = convert(atype, seq[i+1])
        total += sum(ygold .* ypred)
        count += sum(ygold)
        text = ygold
    end

    lossval = -total/count
    push!(values, AutoGrad.getval(lossval))
    return lossval
end

# generate
function generate(w, wcnn, s, vis, vocab, maxlen; beamsize=1)
    atype = typeof(AutoGrad.getval(w[1]))
    if wcnn != nothing
        vis = KnetArray(vis)
        vis = vgg19(wcnn, vis)
        vis = transpose(vis)
    else
        vis = convert(atype, vis)
    end
    vis = vis * w[5]

    # language generation with (sentence, state, probability) array
    sentences = Any[(Any[SOS],s,0.0)]
    while true
        changed = false
        for i = 1:beamsize
            # get current sentence
            curr = shift!(sentences)
            sentence, st, prob = curr

            # get last word
            word = sentence[end]
            if word == EOS || length(sentence) >= maxlen
                push!(sentences, curr)
                continue
            end

            # get probabilities
            onehotvec = zeros(Cuchar, 1, vocab.size)
            onehotvec[word2index(vocab, word)] = 1
            text = convert(atype, onehotvec) * w[6]
            x = hcat(vis, text)
            (st[1], st[2]) = lstm(w[1], w[2], st[1], st[2], x)
            ypred = logp(st[1] * w[3] .+ w[4], 2)
            ypred = convert(Array{Float32}, ypred)[:]

            # add most probable predictions to array
            maxinds = sortperm(ypred, rev=true)
            for j = 1:beamsize
                ind = maxinds[j]
                new_word = index2word(vocab, ind)
                new_sentence = copy(sentence)
                new_state = copy(st)
                new_probability = prob + ypred[ind]
                push!(new_sentence, new_word)
                push!(sentences, (new_sentence, new_state, new_probability))
            end
            changed = true

            # skip first loop
            if word == SOS
                break
            end
        end

        orders = sortperm(map(s -> s[3], sentences), rev=true)
        sentences = sentences[orders[1:beamsize]]

        if !changed
            break
        end
    end

    sentence = first(sentences)[1]
    if sentence[end] == EOS
        pop!(sentence)
    end
    push!(sentence, ".")
    output = join(sentence[2:end], " ")
end

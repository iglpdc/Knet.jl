# TODO: nce
# TODO: importance sampling
# TODO: char based input
# TODO: bidirectional
# TODO: better way to specify winit
# TODO: better way to specify lr decay

for p in ("ArgParse","Distributions","JLD","Knet")
    if Pkg.installed(p) == nothing; Pkg.add(p); end
end

# module RNNLM
using ArgParse,Distributions,JLD,Knet
using AutoGrad: getval
logprint(x)=join(STDERR,[Dates.format(now(),"HH:MM:SS"),x,'\n'],' ')
macro run(i,x) :(if loglevel>=$i; $(esc(x)); end) end
macro msg(i,x) :(if loglevel>=$i; logprint($(esc(x))); end) end
macro log(i,x) :(if loglevel>=$i; logprint($(string(x))); end; $(esc(x))) end


function lstm(weight,bias,hidden,cell,input)            # 2:991  1:992:1617 (id:forw:back)
    gates   = weight * hidden .+ input .+ bias          # 2:312  1:434:499 (43+381+75) (cat+mmul+badd)
    h       = size(hidden,1)                            # 
    forget  = sigm(gates[1:h,:])                        # 2:134  1:98:99  (62+37) (index+sigm)
    ingate  = sigm(gates[1+h:2h,:])                     # 2:99   1:73:123 (77+46)
    outgate = sigm(gates[1+2h:3h,:])                    # 2:113  1:66:124 (87+37)
    change  = tanh(gates[1+3h:4h,:])                    # 2:94   1:51:179 (130+49) replace end with 4h?
    cell    = cell .* forget + ingate .* change         # 2:137  1:106:202 (104+93+5) (bmul+bmul+add)
    hidden  = outgate .* tanh(cell)                     # 2:100  1:69:194 (73+121) (tanh+bmul)
    return (hidden,cell)
end

# using Knet: KnetMatrix
# Base.diag(a::KnetMatrix)=a[1:(1+size(a,1)):length(a)]

function nceloss(model, input, golds, sampleSize, shareSize) # share n samples among k instances
    @assert length(golds) == size(input,2)
    Wy0 = Wy(model)[golds,:]
    by0 = by(model)[golds,:]
    s0 = Wy0 * input .+ by0
    @assert size(s0,1) == size(s0,2) == length(golds)
    s0 = s0[1:(1+size(s0,1)):length(s0)]
    @assert length(s0) == length(golds)
    z0 = log(exp(s0) + (sampleSize * wfreq[golds]))
    @assert length(z0) == length(golds)
    p1 = []

    for i=1:shareSize:length(golds)
        j=min(i+shareSize-1,length(golds))
        n=j-i+1
        # s0[i:j] are going to share the same noise samples
        samples = rand(wdist,sampleSize)
        Wy1 = Wy(model)[samples,:]
        by1 = by(model)[samples,:]
        s1 = Wy1 * input[:,i:j] .+ by1
        @assert size(s1,1)==sampleSize && size(s1,2)==n
        kq = sampleSize * wfreq[samples]
        z1 = log(exp(s1) .+ kq)
        push!(p1, vec(sum(log(kq)) - sum(z1,1)))
    end
    p1 = vcat(p1...)
    @assert length(p1) == length(golds)
    p1 = p1 + s0 - z0
    return p1 / (1+sampleSize)
end

# sequence[t]::Vector{Int} minibatch of tokens
function rnnlm(model, state, sequence; pdrop=0, range=1:(length(sequence)-1), keepstate=nothing, stats=nothing, nce=0, share=0)
    index = vcat(sequence[range]...)
    input = Wm(model)[:,index]                          # 2:15
    input = dropout(input, pdrop)
    for n = 1:nlayers(model)
        input = Wx(model,n) * input                     # 2:26
        w,b,h,c = Wh(model,n),bh(model,n),hdd(state,n),cll(state,n)
        output = []
        j1 = j2 = 0
        for t in range
            j1 = j2 + 1
            j2 = j1 + length(sequence[t]) - 1
            input_t = input[:,j1:j2]                    # 2:35
            (h,c) = lstm(w,b,h,c,input_t)               # 2:991
            push!(output,h)
        end
        if keepstate != nothing
            keepstate[2n-1] = getval(h)
            keepstate[2n] = getval(c)
        end
        input = hcat(output...)                         # 2:39
        input = dropout(input,pdrop)
    end
    golds = vcat(sequence[range+1]...)
    if nce > 0
        logp2 = nceloss(model, input, golds, nce, share)
    else
        logp0 = Wy(model) * input .+ by(model)
        logp1 = logp(logp0,1)
        @assert length(golds) == size(logp1,2)
        index = golds + size(logp1,1)*(0:(size(logp1,2)-1))
        logp2 = logp1[index]
    end
    total = sum(logp2)
    nword = length(golds)
    if stats != nothing
        stats[1]=total
        stats[2]=nword
    end
    batch = length(sequence[1])
    # return -total / nword # per token loss: scale does not depend on sequence length or minibatch
    return -total / batch   # per sequence loss: does not depend on minibatch, larger loss for longer seq
    # return -total 	    # total loss: longer sequences and larger minibatches have higher loss
end

rnnlmgrad = grad(rnnlm)

# data[t][b] contains word[(b-1)*T+t]
function bptt(model, data, optim; slen=20, o...) # pdrop=0, slen=20, nce=0)
    T = length(data)
    B = length(data[1])
    state = initstate(model,B)
    @run 2 begin
        wnorm = zeros(length(model))
        gnorm = zeros(length(model))
        nword = 0
    end
    for i = 1:slen:(T-1)
        j = i+slen-1
        if j >= T; break; end
        grads = rnnlmgrad(model, state, data; range=i:j, keepstate=state, o...)
        @run 2 begin
            gnorm += map(vecnorm,grads)
            wnorm += map(vecnorm,model)
            nword += 1
        end
        update!(model, grads, optim)
    end
    @msg 2 string("wnorm=",wnorm./nword)
    @msg 2 string("gnorm=",gnorm./nword)
end

function loss(model, data; slen=20)
    T = length(data)
    B = length(data[1])
    state = initstate(model,B)
    rat=zeros(2); tot=zeros(2)
    for i = 1:slen:(T-1)
        j = i+slen-1
        if j >= T; break; end
        rnnlm(model, state, data; stats=rat, range=i:j, keepstate=state)
        tot += rat
    end
    return (-tot[1],tot[2])
end

nlayers(model)=div(length(model)-3,3)
Wm(model)=model[1]
Wx(model,n)=model[3n-1]
Wh(model,n)=model[3n]
bh(model,n)=model[3n+1]
Wy(model)=model[end-1]
by(model)=model[end]
hdd(state,n)=state[2n-1]
cll(state,n)=state[2n]

function initmodel(atype, hidden, vocab, embed)
    init(d...)=atype(xavier(Float32,d...))
    # init(d...)=atype(rand(Float32,d...)*0.0002-0.0001)
    bias(d...)=atype(zeros(Float32,d...))
    N = length(hidden)
    model = Array(Any, 3N+3)
    model[1] = init(embed,vocab) # Wm
    X = embed
    for n = 1:N
        H = hidden[n]
        model[3n-1] = init(4H,X) # Wx
        model[3n]   = init(4H,H) # Wh
        model[3n+1] = bias(4H,1) # bh
        model[3n+1][1:H] = 1     # forget gate bias = 1
        X = H
    end
    model[3N+2] = init(vocab,hidden[end]) # Wy
    model[3N+3] = bias(vocab,1)           # by
    return model
end

let blank = nothing; global initstate
function initstate(model, batch)
    N = nlayers(model)
    state = Array(Any, 2N)
    for n = 1:N
        bias = bh(model,n)
        hidden = div(length(bias),4)
        if typeof(blank)!=typeof(bias) || size(blank)!=(hidden,batch)
            blank = fill!(similar(bias, hidden, batch),0)
        end
        state[2n-1] = state[2n] = blank
    end
    return state
end
end

# initoptim creates optimization parameters for each numeric weight
# array in the model.  This should work for a model consisting of any
# combination of tuple/array/dict.
initoptim{T<:Number}(::KnetArray{T},otype)=eval(parse(otype))
initoptim{T<:Number}(::Array{T},otype)=eval(parse(otype))
initoptim(a::Associative,otype)=Dict(k=>initoptim(v,otype) for (k,v) in a) 
initoptim(a,otype)=map(x->initoptim(x,otype), a)

# Q: charlm flat minibatch style or sort sentences? => flat
# Q: padding or masking? => no need
# Q: initial state zero or learnt? => zero
# Q: partial batches => no need

function minibatch(data, B)
    T = div(length(data),B)
    batches = Array(Vector{Int32},T)
    for t = 1:T
        batch = Array(Int32,B)
        for b = 1:B
            batch[b] = data[(b-1)*T+t]
        end
        batches[t] = batch
    end
    return batches
end

function initvocab()
    global EOS = Int32(1) # use as both SOS in input and EOS in output.
    Dict{String,Int32}("<s>"=>EOS)
end

function loaddata(file, vocab, wfreq)
    data = Int32[EOS]; nw = ns = 0
    for l in eachline(file); ns+=1
        for w in split(l); nw+=1
            i = get!(vocab, w, 1+length(vocab))
            push!(data, i)
            wfreq[i] += 1
        end
        push!(data,EOS)
        wfreq[EOS] += 1
    end
    @msg 1 "$file: $ns sentences, $nw words, vocab=$(length(vocab)), corpus=$(length(data))"
    return data
end

function mikolovptb()
    files = [ Knet.dir("data","ptb.$x.txt") for x in ("train","valid","test") ]
    if any(!isfile(f) for f in files)
        tgz = Knet.dir("data","simple-examples.tgz")
        if !isfile(tgz)
            url = "http://www.fit.vutbr.cz/~imikolov/rnnlm/simple-examples.tgz"
            download(url,tgz)
        end
        run(`tar --strip-components 3 -C $(Knet.dir("data")) -xzf $tgz ./simple-examples/data/ptb.train.txt ./simple-examples/data/ptb.valid.txt ./simple-examples/data/ptb.test.txt`)
    end
    return files
end

function main(args=ARGS)
    global model, text, data, tok2int, o
    s = ArgParseSettings()
    s.description="rnnlm.jl: LSTM language model\n"
    s.exc_handler=ArgParse.debug_handler
    @add_arg_table s begin
        ("--datafiles"; nargs='+'; help="If provided, use first file for training, second for early stop, others for test. If not provided use mikolovptb files.")
        ("--loadfile"; help="Initialize model from file")
        ("--savefile"; help="Save final model to file")
        ("--bestfile"; help="Save best model to file")
        ("--epochs"; arg_type=Int; default=5; help="Number of epochs for training.")
        ("--hidden"; nargs='+'; arg_type=Int; default=[256]; help="Sizes of one or more LSTM layers.")
        ("--embed"; arg_type=Int; default=128; help="Size of the embedding vector.")
        ("--batchsize"; arg_type=Int; default=64; help="Number of sequences to train on in parallel.")
        ("--share"; arg_type=Int; default=64; help="NCE sharing.")
        ("--bptt"; arg_type=Int; default=20; help="Number of steps to unroll for bptt.")
        ("--optimization"; default="Adagrad()"; help="Optimization algorithm and parameters.")
        ("--dropout"; arg_type=Float64; default=0.0; help="Dropout probability.")
        ("--gcheck"; arg_type=Int; default=0; help="Check N random gradients.")
        ("--seed"; arg_type=Int; default=-1; help="Random number seed.")
        ("--atype"; default=(gpu()>=0 ? "KnetArray{Float32}" : "Array{Float32}"); help="array type: Array for cpu, KnetArray for gpu")
        ("--fast"; action=:store_true; help="skip loss printing for faster run")
        ("--nce";  arg_type=Int; default=0; help="number of nce samples.")
        ("--loglevel"; arg_type=Int; default=2; help="display progress messages")
        # TODO: ("--generate"; arg_type=Int; default=0; help="If non-zero generate given number of tokens.")
    end
    isa(args, AbstractString) && (args=split(args))
    o = parse_args(args, s; as_symbols=true)
    global loglevel = o[:loglevel]
    if o[:seed] > 0; setseed(o[:seed]); end
    if isempty(o[:datafiles]); o[:datafiles] = mikolovptb(); end
    @msg 1 string(s.description,"opts=",[(k,v) for (k,v) in o]...)
    global vocab = initvocab()
    global wfreq = zeros(10000) # TODO
    global text = map(f->loaddata(f,vocab,wfreq), o[:datafiles])
    wfreq ./= sum(wfreq) # TODO
    global wdist = Categorical(wfreq)
    wfreq = KnetArray{Float32}(wfreq)
    global data = map(t->minibatch(t, o[:batchsize]), text)
    global model = initmodel(eval(parse(o[:atype])), o[:hidden], length(vocab), o[:embed])
    @msg 1 (:usable_data,[length(d[1]) * o[:bptt] * div(length(d),o[:bptt]) for d in data]...)
    function report(ep)
        l = [ loss(model,d;slen=o[:bptt]) for d in data ]
        l1 = Float32[ exp(x[1]/x[2]) for x in l ]
        l2 = [ x[2] for x in l ]
        if ep==0; @msg 1 (:epoch,ep,:perp,l1...,:size,l2...)
        else; @msg 1 (:epoch,ep,:perp,l1...); end
        return l1
    end
    if length(data) > 1; devset=2; else devset=1; end
    if !o[:fast]; @log 1 (losses = report(0)); devbest = devlast = losses[devset]; end
    global optim = initoptim(model,o[:optimization])
    Knet.knetgc(); gc() # TODO: fix this otherwise curand cannot initialize no memory left!
    for epoch=1:o[:epochs]
        bptt(model, data[1], optim; pdrop=o[:dropout], slen=o[:bptt], nce=o[:nce], share=o[:share])
        if o[:fast]; continue; end
        @log 1 (losses = report(epoch))
        if o[:bestfile] != nothing && losses[devset] < devbest
            devbest = losses[devset]
            @log 1 save(o[:bestfile], "model", model, "vocab", vocab)
        end
        # if epoch > 6 # losses[devset] > devlast && isa(optim[1], Sgd)
        #     for p in optim; p.lr /= 1.2; end; @msg 1 "lr=$(optim[1].lr)"
        # end
        devlast = losses[devset]
        if o[:gcheck] > 0
            gradcheck(rnnlm, model, initstate(model,o[:batchsize]), data[1]; gcheck=o[:gcheck], verbose=true, kwargs=[(:range,1:o[:bptt])])
        end
    end
    if o[:savefile] != nothing
        @log 1 save(o[:savefile], "model", model, "vocab", vocab)
    end
    return model
end


# This allows both non-interactive (shell command) and interactive calls like:
# $ julia rnnlm.jl --epochs 10
# julia> RNNLM.main("--epochs 10")
if VERSION >= v"0.5.0-dev+7720"
    if basename(PROGRAM_FILE)==basename(@__FILE__); main(ARGS); end
else
    !isinteractive() && !isdefined(Core.Main,:load_only) && main(ARGS)
end

# end  # module

#=
        vocab = size(Wy(model),1)
        @assert length(golds) == size(input,2)
        # qi = 1/vocab

        Wy1 = Wy(model)[golds,:]
        by1 = by(model)[golds,:]
        score = Wy1 * input .+ by1
        @assert size(score,1) == size(score,2) == length(golds)
        diags = 1:(1+size(score,1)):length(score)
        s0 = score[diags]
        @assert length(s0) == length(golds)
        # q0 = 1/vocab

        k = length(golds)-1

        kq0 = k * wfreq[golds]
        z0 = log(exp(s0) .+ kq0)

        # exclude the diags here?
        s1 = sum(log(kq0))
        z1 = vec(sum(log(exp(score) .+ kq0), 1))

        # 0. small bptt+batch in rnnlm.jl works
        # 1. modify rnnlm1.jl to sample noise for each token minibatch
        # 1a. try uniform distro instead of unigram
        # 2. experiment with rnnlm.jl to sample noise for each sequence minibatch
        # 2a. compare with one sample per instance
        # 3. experiment with using minibatch as its own noise samples

        #=
        k = nce
        # rnd = rand(1:vocab, nce)
        rnd = rand(wdist, nce)
        Wy2 = Wy(model)[rnd,:]
        by2 = by(model)[rnd,:]
        score = Wy2 * input .+ by2
        @assert size(score,1)==nce && size(score,2)==length(golds)
        # kq = k*(1/vocab)
        kq = k*wfreq[rnd]
        s1 = sum(log(kq))
        z1 = vec(sum(log(exp(score) .+ kq), 1))
        =#
        
        logp2 = (s0 - z0 + s1 - z1) / (k+1)
=#

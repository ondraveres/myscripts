# for ((i=1;i<=20;i+=1)); do  for d in  one_of_1_2trees  one_of_1_5trees  one_of_1_paths  one_of_2_5trees  one_of_2_paths  one_of_5_paths ; do  julia -p 24 artificial.jl --dataset $d --incarnation $i ; done ; done

using Pkg;
cd("/home/veresond/ExplainMill.jl/myscripts/datasets");
Pkg.activate("..");
using ArgParse;
using Flux;
using Mill;
using JsonGrinder;
using JSON;
using BSON;
using Statistics;
using IterTools;
using PrayTools;
using StatsBase;
using ExplainMill;
using Serialization;
using Setfield;
using DataFrames;
using ExplainMill: jsondiff, nnodes, nleaves;
include("common.jl");
include("loader.jl");
include("stats.jl");
using PrintTypesTersely;
function StatsBase.predict(mymodel::Mill.AbstractMillModel, ds::Mill.AbstractMillNode, ikeyvalmap)
    o = mapslices(x -> ikeyvalmap[argmax(x)], mymodel(ds), dims=1)
end;
PrintTypesTersely.off();
_s = ArgParseSettings();
@add_arg_table! _s begin
    ("--dataset"; default = "mutagenesis"; arg_type = String)
    ("--task"; default = "one_of_1_5trees"; arg_type = String)
    ("--incarnation"; default = 1; arg_type = Int)
    ("-k"; default = 5; arg_type = Int)
end
;
settings = parse_args(ARGS, _s; as_symbols=true);



settings = NamedTuple{Tuple(keys(settings))}(values(settings));

model_name = "hundreditermodel22_1.bson"

###############################################################
# start by loading all samples
###############################################################
;
samples, labels, concepts = loaddata(settings);
loaddata(settings)[3];
concepts;
labels = vcat(labels, fill(2, length(concepts)));
samples = vcat(samples, concepts);

resultsdir(s...) = joinpath("..", "..", "data", "sims", settings.dataset, settings.task, "$(settings.incarnation)", s...);
println("start");
println("resultsdir() = ", resultsdir());
###############################################################
# create schema of the JSON
###############################################################
sch = JsonGrinder.schema(vcat(samples, concepts, Dict()));
if !isfile(resultsdir(model_name))
    !isdir(resultsdir()) && mkpath(resultsdir())
    sch = JsonGrinder.schema(vcat(samples, concepts, Dict()))
    extractor = suggestextractor(sch)

    trndata = extractbatch(extractor, samples)
    function makebatch()
        i = rand(1:2000, 100)
        trndata[i], Flux.onehotbatch(labels[i], 1:2)
    end
    ds = extractor(JsonGrinder.sample_synthetic(sch))
    good_model, concept_gap = nothing, 0
    # good_model, concept_gap
    local model = reflectinmodel(
        sch,
        extractor,
        d -> Dense(d, settings.k, relu),
        all_imputing=true,
        # b = Dict("" => d -> Chain(Dense(d, settings.k, relu), Dense(settings.k, 2)))
    )
    model = @set model.m = Chain(model.m, Dense(settings.k, 2))
    for i in 1:2



        @info "start of epoch $i"
        ###############################################################
        #  train
        ###############################################################
        opt = ADAM()
        ps = Flux.params(model)
        loss = (x, y) -> Flux.logitcrossentropy(model(x), y)
        data_loader = Flux.DataLoader((trndata, Flux.onehotbatch(labels, 1:2)), batchsize=100, shuffle=true)


        Flux.Optimise.train!(loss, ps, data_loader, opt)

        soft_model = @set model.m = Chain(model.m, softmax)
        cg = minimum(map(c -> ExplainMill.confidencegap(soft_model, extractor(c), 2)[1, 1], concepts))
        eg = ExplainMill.confidencegap(soft_model, extractor(JSON.parse("{}")), 1)[1, 1]
        predictions = model(trndata)
        accuracy(ds, y) = mean(Flux.onecold(model(ds)) .== y)
        acc = mean(Flux.onecold(predictions) .== labels)
        @info "crossentropy on all samples = ", Flux.logitcrossentropy(predictions, Flux.onehotbatch(labels, 1:2)),
        @info "accuracy on all samples = ", acc
        @info "minimum gap on concepts = $(cg) on empty sample = $(eg)"
        @info "accuracy on concepts = $( accuracy(extractor.(concepts), 2)))"
        @info "end of epoch $i"
        flush(stdout)

        mean(Flux.onecold(predictions) .== labels)

        if (acc > 0.95)
            break
        end
        # if cg > 0 && eg > 0
        #     if cg > concept_gap
        #         good_model, concept_gap = model, cg
        #     end
        # end
        # concept_gap > 0.95 && break
    end
    if concept_gap < 0
        error("Failed to train a model")
    end
    #model = good_model
    BSON.@save resultsdir(model_name) model extractor sch
end;


resultsdir();
using Flux;
isfile(resultsdir(model_name));
d = BSON.load(resultsdir(model_name));




(model, extractor, sch) = d[:model], d[:extractor], d[:sch];
statlayer = StatsLayer()
;
model = @set model.m = Chain(model.m, statlayer);
soft_model = @set model.m = Chain(model.m, softmax);
logsoft_model = @set model.m = Chain(model.m, logsoftmax);


###############################################################
#  Helper functions for explainability
###############################################################
const ci = PrayTools.classindexes(labels)
ci

ci

function loadclass(k, n=typemax(Int))
    dss = map(s -> extractor(s, store_input=true), sample(samples[ci[k]], min(n, length(ci[k])), replace=false))
    reduce(catobs, dss)
end


function onlycorrect(dss, i, min_confidence=0)
    correct = predict(soft_model, dss, [1, 2]) .== i
    dss = dss[correct[:]]
    min_confidence == 0 && return (dss)
    correct = ExplainMill.confidencegap(soft_model, dss, i) .>= min_confidence
    dss[correct[:]]
end

Random.seed!(settings.incarnation)
strain = 2
ds = loadclass(strain, 1000)
if false

    extractor(samples[10111], store_input=true).metadata
    i = strain
    concept_gap = minimum(map(c -> ExplainMill.confidencegap(soft_model, extractor(c), i)[1, 1], concepts))
    sample_gap = minimum(map(c -> ExplainMill.confidencegap(soft_model, extractor(c), i)[1, 1], samples[labels.==2]))
    threshold_gap = 0.2#floor(0.9 * concept_gap, digits=2)
    # correct = predict(soft_model, ds, [1, 2])
    # argmax(soft_model(ds[1]))
    # soft_model(ds)
    # mean(Flux.onecold(model(ds) .== labels))
    # mean(labels)
    # mean(Flux.onecold(soft_model(ds)) .== labels)
    # mean(correct)


    # ExplainMill.confidencegap(soft_model, ds, 2)
    correct_ds = onlycorrect(ds, strain, 0.1)
    ds = correct_ds
    @info "minimum gap on concepts = $(concept_gap) on samples = $(sample_gap)"

    heuristic = [:Flat_HAdd, :Flat_HArr, :Flat_HArrft, :LbyL_HAdd, :LbyL_HArr, :LbyL_HArrft]
    uninformative = [:Flat_Gadd, :Flat_Garr, :Flat_Garrft, :LbyL_Gadd, :LbyL_Garr, :LbyL_Garrft]
    variants = vcat(
        collect(Iterators.product(["stochastic"], vcat(uninformative, heuristic)))[:],
        collect(Iterators.product(["grad", "gnn", "gnn2", "banz"], vcat(heuristic)))[:],
    )
    ds = ds[1:min(numobs(ds), 100)]
    function getexplainer(name)
        if name == "stochastic"
            return ExplainMill.StochasticExplainer()
        elseif name == "grad"
            return ExplainMill.GradExplainer2()
        elseif name == "gnn"
            return ExplainMill.GnnExplainer()
        elseif name == "gnn2"
            return ExplainMill.GnnExplainer()
        elseif name == "banz"
            return ExplainMill.DafExplainer()
        else
            error("unknown eplainer $name")
        end
    end

    PrintTypesTersely.on()

    ExplainMill.DafExplainer()
    exdf = DataFrame()
    numobs(ds)
    variants
    if false
        if !isfile(resultsdir("stats_" * model_name))
            for (name, pruning_method) in variants
                e = getexplainer(name)
                @info "explainer $e on $name with $pruning_method"
                flush(stdout)
                #addexperiment(DataFrame(), e, ds[1], logsoft_model, i, n, threshold_gap, name, pruning_method, 1, settings, statlayer)
                for j in 1:numobs(ds)
                    global exdf
                    exdf = addexperiment(exdf, e, ds[j], logsoft_model, 2, 0, 0.1, name, pruning_method, j, settings, statlayer)
                end
                BSON.@save resultsdir("stats_" * model_name) exdf
            end
        end
    end
end


using HierarchicalUtils
### the real deal
function iterate_over(mask, ds, extractor, sch)
    # Iterate over the keys of the dictionaries
    for key in keys(ds)
        # Check if the value associated with the key is a dictionary
        if ds[key] isa Dict
            # Recursive case: iterate over this dictionary
            @info "going deeper"
            iterate_over(mask[key], ds[key], extractor[key], sch[key])
        else
            # Base case: perform perturbation on the leaf node
            # ds[key] = perturb(ds[key])
            @info "leaf"
        end
    end
end

### the players
PrintTypesTersely.off()

mysample = ds[1]

mask = ExplainMill.create_mask_structure(mysample, d -> ExplainMill.ParticipationTracker(SimpleMask(ones(Bool, d))))

sch[:lumo]
mysample[:lumo]
extractor[:lumo]
mask[:lumo]

printtree(mysample)

typeof(mysample)

iterate_over(mask, ds[1], extractor, sch)


mk = ExplainMill.stats(ExplainMill.StochasticExplainer(), ds[1], model)
o = softmax(model(ds[1]))[:]
τ = 0.9 * maximum(o)
class = argmax(softmax(model(ds[1]))[:])
f = () -> softmax(model(ds[1][mk]))[class] - τ
ExplainMill.levelbylevelsearch!(f, mask)

logical = ExplainMill.e2boolean(ds[1], mask, extractor)


# typeof(Mill.children(mysample))

# Mill.children(sch)

# for (name, value) in pairs(Mill.children(ds))
#     println("Name: ", name)
#     println("Value: ", value)
#     @info Mill.NodeType(value)
# end

# extractor[:atoms]

# Mill.children(extractor[:atoms].item)

# HierarchicalUtils.nleafs(mysample)

# NodeIterator(mysample) |> collect

# LeafIterator(mysample, mask) |> collect
# LeafIterator(mask) |> collect


global_data_node = nothing
global_mask_node = nothing
global_schema_node = nothing
global_extractor_node = nothing

leafmap!(mysample, mask, sch, extractor; complete=false, order=LevelOrder()) do (data_node, mask_node, schema_node, extractor_node)
    data_node.data
    data_node.metadata
    mask_node.mask.m
    schema_node.counts
    global global_data_node = data_node
    global global_mask_node = mask_node
    global global_schema_node = schema_node
    global global_extractor_node = extractor_node

    global_data_node.data
    global_mask_node.mask.m.x
    for i in 1:length(global_mask_node.mask.m.x)

        @info global_mask_node.mask.m.x[i]
    end
    # extractor_node.n
    # extractor_node.keyvalemap
    # extractor_node.uniontypes
end


flat_view = ExplainMill.FlatView(mask)
mask_bool_vector = [flat_view[i] for i in 1:length(flat_view.itemmap)]

@show global_data_node.data


global_mask_node.mask.m.x


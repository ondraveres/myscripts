# for ((i=1;i<=20;i+=1)); do  for d in  one_of_1_2trees  one_of_1_5trees  one_of_1_paths  one_of_2_5trees  one_of_2_paths  one_of_5_paths ; do  julia -p 24 artificial.jl --dataset $d --incarnation $i ; done ; done
using Pkg, ArgParse, Flux, Mill, JsonGrinder, JSON, BSON, Statistics, IterTools, PrayTools, StatsBase, ExplainMill, Serialization, Setfield, DataFrames, HierarchicalUtils, Random, JLD2, GLMNet, Plots, Zygote
using ExplainMill: jsondiff, nnodes, nleaves

try
    cd("/Users/ondrejveres/Diplomka/ExplainMill.jl/myscripts/datasets")
catch
    cd("/home/veresond/ExplainMill.jl/myscripts/datasets")
end
Pkg.activate("..")
include("treelime.jl")
include("common.jl")
include("loader.jl")
include("stats.jl")


_s = ArgParseSettings()
@add_arg_table! _s begin
    ("--dataset"; default = "mutagenesis"; arg_type = String)
    ("--task"; default = "one_of_1_5trees"; arg_type = String)
    ("--incarnation"; default = 8; arg_type = Int)
    ("-k"; default = 5; arg_type = Int)
end
settings = parse_args(ARGS, _s; as_symbols=true)
settings = NamedTuple{Tuple(keys(settings))}(values(settings))

sample_num = 2
iter_count = 2
k_variants = [3]


###############################################################
# start by loading all samples
###############################################################

samples, labels, concepts = loaddata(settings)
labels = vcat(labels, fill(2, length(concepts)))
samples = vcat(samples, concepts)

resultsdir(s...) = joinpath("..", "..", "data", "sims", settings.dataset, settings.task, "$(settings.incarnation)", s...)
###############################################################
# create schema of the JSON
###############################################################
schema_file = resultsdir("schema.jdl2")
sch = nothing
if isfile(schema_file)
    @info "Schema file exists, loading from file"
    global sch = load(schema_file, "sch")
else
    @info "Schema file does not exist, creating new schema"
    global sch = JsonGrinder.schema(vcat(samples, concepts, Dict()))
    @save schema_file sch = sch
end

exdf = DataFrame()
extractor = suggestextractor(sch)
stats_filename = "stability_data3.bson"
if !isfile(resultsdir(stats_filename))
    for model_variant_k in k_variants
        global extractor
        global sch
        model_name = "my-2-march-model-variant-$(model_variant_k).bson"
        if !isfile(resultsdir(model_name))
            !isdir(resultsdir()) && mkpath(resultsdir())
            trndata = extractbatch(extractor, samples)
            function makebatch()
                i = rand(1:2000, 100)
                trndata[i], Flux.onehotbatch(labels[i], 1:2)
            end
            ds = extractor(JsonGrinder.sample_synthetic(sch))
            good_model, concept_gap = nothing, 0
            # good_model, concept_gap
            model = reflectinmodel(
                sch,
                extractor,
                d -> Dense(d, model_variant_k, relu),
                all_imputing=true
            )
            model = @set model.m = Chain(model.m, Dense(model_variant_k, 2))
            for i in 1:iter_count
                @info "start of epoch $i"
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
                if (acc > 0.999)
                    break
                end
            end
            if concept_gap < 0
                error("Failed to train a model")
            end
            BSON.@save resultsdir(model_name) model extractor sch
        end
        d = BSON.load(resultsdir(model_name))
        (model, extractor, sch) = d[:model], d[:extractor], d[:sch]
        statlayer = StatsLayer()
        model = @set model.m = Chain(model.m, statlayer)
        soft_model = @set model.m = Chain(model.m, softmax)
        logsoft_model = @set model.m = Chain(model.m, logsoftmax)
        my_class_indexes = PrayTools.classindexes(labels)
        Random.seed!(settings.incarnation)
        strain = 2
        ds = loadclass(strain, my_class_indexes, 3)
        i = strain
        concept_gap = minimum(map(c -> ExplainMill.confidencegap(soft_model, extractor(c), i)[1, 1], concepts))
        sample_gap = minimum(map(c -> ExplainMill.confidencegap(soft_model, extractor(c), i)[1, 1], samples[labels.==2]))
        threshold_gap = 0.2
        correct_ds = onlycorrect(ds, strain, soft_model, 0.1)
        ds = correct_ds
        @info "minimum gap on concepts = $(concept_gap) on samples = $(sample_gap)"


        heuristic = [:Flat_HAdd, :Flat_HArr, :Flat_HArrft, :LbyL_HAdd, :LbyL_HArr, :LbyL_HArrft]
        uninformative = [:Flat_Gadd, :Flat_Garr, :Flat_Garrft, :LbyL_Gadd, :LbyL_Garr, :LbyL_Garrft]
        variants = vcat(
            collect(Iterators.product(["stochastic"], vcat(uninformative, heuristic)))[:],
            collect(Iterators.product(["grad", "gnn", "banz"], vcat(heuristic)))[:],
        )
        ds = ds[1:min(numobs(ds), sample_num)]

        for (name, pruning_method) in variants
            e = getexplainer(name)
            @info "explainer $e on $name with $pruning_method"
            flush(stdout)
            for j in 1:numobs(ds)
                global exdf
                exdf = addexperiment(exdf, e, ds[j], logsoft_model, 2, 0.9, name, pruning_method, j, settings, statlayer, model_variant_k, extractor)
            end
        end
        for j in 1:numobs(ds)
            global exdf
            exdf = add_treelime_experiment(exdf, ds[j], logsoft_model, 2, j, settings, statlayer, model_variant_k, extractor)
        end
    end
    @save resultsdir(stats_filename) exdf
end

# add_treelime_experiment(exdf, ds[1], logsoft_model, 2, 1, settings, statlayer, model_variant_k, extractor)

# dd = ds[2]
# ms = treelime(dd, logsoft_model, extractor, schema)

# fv = ExplainMill.FlatView(ms);
# num_true = 0
# for i in 1:length(fv)
#     if fv[i]
#         num_true += 1
#     end
# end
# num_true

# logical = ExplainMill.e2boolean(dd, ms, extractor)
# nnodes(logical)
# ExplainMill.useditems(fv)

# fv

# ms[:lumo]

# ms[:inda].mask.x

# HierarchicalUtils.nnodes(ms)
# HierarchicalUtils.nnodes(dd)
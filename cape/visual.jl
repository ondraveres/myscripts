using Plots
using Measures
using JLD2

@load "cg_lambda_plot_10.jld2" lambdas cgs non_zero_lengths
# lambdas[1010]
non_zero_lengths
plots = []
for n in [10, 50, 100, 200, 400, 1000]
    @load "cg_lambda_plot_$(n).jld2" lambdas cgs non_zero_lengths
    ticks = range(minimum(non_zero_lengths), maximum(non_zero_lengths), step=10)
    p = plot(non_zero_lengths, cgs, xlabel="lenghts", ylabel="Confidence Gaps", title="Confidence Gaps vs Lengths $(n)", legend=false, xlims=(0, 200))#, xticks=ticks)
    # Add small dots where the points are
    scatter!(p, non_zero_lengths, cgs, markersize=2, markercolor=:darkblue, markerstrokecolor=:darkblue)

    # Highlight the line which represents zero confidence gap
    hline!(p, [0], color=:green, linewidth=1)

    positive_cgs = cgs .> 0
    if any(positive_cgs)
        max_lambda_index = findmax(lambdas[positive_cgs])[2]
        max_lambda = lambdas[positive_cgs][max_lambda_index]
        max_cg = cgs[positive_cgs][max_lambda_index]


        # Add the point to the plot
        scatter!(p, [non_zero_lengths[max_lambda_index]], [max_cg], color=:red, markersize=4)
    end

    push!(plots, p)
end

# Combine the plots in a 2 by 3 grid
p = plot(plots..., layout=grid(5, 2), size=(1000, 1000))

# Display the plot
display(p)
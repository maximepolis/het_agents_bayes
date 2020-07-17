clear all;
addpath('auxiliary_functions/dynare', 'auxiliary_functions/likelihood', 'auxiliary_functions/mcmc', 'auxiliary_functions/sim');


%% Settings

% Decide what to do
is_data_gen = 1; % whether simulate data:  
                 % 0: no simulation
                 % 1: simulation
likelihood_type = 1; % =1: Macro + full-info micro; =2: macro + full-info micro, no truncation; =3: macro + moments micro

% Model/data settings
T = 50;                                 % Number of periods of simulated macro data
ts_micro = 10:10:T;                         % Time periods where we observe micro data
N_micro = 1e2;                          % Number of micro entities per non-missing time period
trunc_logn = -1.1271;                   % Micro sample selection: Lower truncation point for log(n)

% Parameter transformation
transf_to_param = @(x) [1/(1+exp(-x(1))) exp(x(2:end))];    % Function mapping transformed parameters into parameters of interest
param_to_transf = @(x) [log(x(1)/(1-x(1))) log(x(2:end))];  % Function mapping parameters of interest into transformed parameters

% Prior
prior_logdens_transf = @(x) sum(x) - 2*log(1+exp(x(1)));    % Log prior density of transformed parameters
prior_init_transf = @() param_to_transf([0.7 0.02]);        % Distribution of initial transformed draw

% Optimization settings
is_optimize = true;                                                     % Find posterior mode?
optim_grid = combvec(linspace(0.001,0.99,5),linspace(0.01,0.1,5))';    % Optimization grid

% MCMC settings
mcmc_num_iter = 1e4;                  % Number of MCMC steps (total)
mcmc_thin = 1;                         % Store every X draws
mcmc_stepsize_init = 1e-2;              % Initial MCMC step size
mcmc_adapt_iter = [50 200 500 1000];          % Iterations at which to update the variance/covariance matrix for RWMH proposal; first iteration in list is start of adaptation phase
mcmc_adapt_diag = false;                 % =true: Adapt only to posterior std devs of parameters, =false: adapt to full var/cov matrix
mcmc_adapt_param = 10;                  % Shrinkage parameter for adapting to var/cov matrix (higher values: more shrinkage)
mcmc_filename = 'mcmc_moments.mat';             % File name of MCMC output

% for adaptive RWMH
mcmc_c = 0.55;
mcmc_ar_tg = 0.3;

% Likelihood settings
num_smooth_draws = 500;                 % Number of draws from the smoothing distribution (for unbiased likelihood estimate)
num_interp = 100;                       % Number of interpolation grid points for calculating density integral

% Numerical settings
num_burnin_periods = 100;               % Number of burn-in periods for simulations
rng_seed = 202006221;                    % Random number generator seed for initial simulation

%% Set economic parameters 

global ttheta nnu ddelta rrhoProd ssigmaProd aaUpper aaLower ppsiCapital ...
	bbeta ssigma pphi nSS rrhoTFP ssigmaTFP rrhoQ ssigmaQ corrTFPQ  cchi

% Technology
ttheta 			= .256;								% capital coefficient
nnu 				= .64;								% labor coefficient
ddelta 			= .085;								% depreciation (annual)
rrhoProd 		= .53; %.859; 								% persistence of idiosyncratic shocks (annual)
ssigmaProd 	= .0364; %.022;								% SD innovations of idiosycnratic shocks (annual)
aaUpper 		= .011; 								% no fixed cost region upper bound
aaLower 		= -.011;								% no fixed cost region lower bound
ppsiCapital 	= .0083;							% upper bound on fixed adjustment cost draws
% ppsiCapital     = 1e-5; 

% Preferences
bbeta 			= .961;								% discount factor (annual)
ssigma 			= 1;									% coefficient of relative risk aversion
pphi 				= 1 / 1e5;							% inverse Frisch elasticity of labor supply
nSS 				= 1 / 3;								% hours worked in steady state
cchi				= 1;									% labor disutility (will be calibrated in Dynare's steady state file to ensure labor supply = nSS)

% Aggregate shocks
rrhoTFP			= 0.859;							% persistence of aggregate TFP (annual)
ssigmaTFP		= .014;								% SD of innovations of aggregate TFP (annual)
rrhoQ				= 0.859;							% persistence of aggregate investment-specific shock (annual)
ssigmaQ		= .014;								% SD of innovations of aggregate investment-specific shock (annual)
corrTFPQ		= 0;									% loading on TFP shock in evolution of investment-specific shock

%% Set approximation parameters

global nProd nCapital nState prodMin prodMax capitalMin capitalMax nShocks nProdFine nCapitalFine nStateFine ...
	maxIterations tolerance acc dampening nMeasure nStateQuadrature nMeasureCoefficients nProdQuadrature ...
	nCapitalQuadrature kRepSS wRepSS

% Order of approximation of value function
nProd 			= 3;										% order of polynomials in productivity
nCapital 		= 5;										% order of polynomials in capital
nState 			= nProd * nCapital;					% total number of coefficients

% Shocks 
nShocks 		= 3;										% order of Gauss-Hermite quadrature over idiosyncratic shocks

% Finer grid for analyzing policy functions and computing histogram
nProdFine 		= 60;
nCapitalFine 	= 40;
nStateFine 	= nProdFine * nCapitalFine;

% Iteration on value function
maxIterations	= 100;
tolerance 		= 1e-6;
acc 				= 500;									% number of iterations in "Howard improvement step"
dampening 	= 0;										% weight on old iteration in updating step

% Approximation of distribution
nMeasure 				= 2;							% order of polynomial approximating distribution
nProdQuadrature 		= 8; 							% number of quadrature points in productivity dimension
nCapitalQuadrature 	= 10;						% number of quadrature points in capital dimension
nStateQuadrature 		= nProdQuadrature * nCapitalQuadrature;
nMeasureCoefficients 	= (nMeasure * (nMeasure + 1)) / 2 + nMeasure;

%% Save parameters

cd('./auxiliary_functions/dynare');
delete steady_vars.mat;
saveParameters;


%% Initial Dynare run

rng(rng_seed);
dynare dynamicModel noclearall nopathchange; % Run Dynare once to process model file


%% Simulate data

if is_data_gen == 0
    
    % Load previous data
%     load('simul_moments.mat')
    load('simul_data_micro.mat');
%     load('simul_data_micro_indv_param.mat');
    
else
    
    % Simulate
    set_dynare_seed(rng_seed);                                          % Seed RNG
    simul_data;
    
end


%% Optimize over grid to find approximate mode

poolobj = parpool;

if is_optimize
    
    optim_numgrid = size(optim_grid,1);
    optim_logpost = nan(optim_numgrid,1);
    
    disp('Optimization...');
    
    for i_optim=1:optim_numgrid % Cycle through grid points
        
        the_param = optim_grid(i_optim,:);
        fprintf(['%s' repmat('%6.4f ',1,length(the_param)),'%s\n'], 'current  [rrhoProd,ssigmaProd] = [',...
        the_param,']');
        the_aux = num2cell(the_param);
        [rrhoProd,ssigmaProd] = deal(the_aux{:});
        
        try
            the_loglike = aux_compute_likel(simul_data_micro, ts_micro, ...
                                   num_smooth_draws, trunc_logn, num_burnin_periods, ...
                                   M_, oo_, options_, ...
                                   likelihood_type);
            the_logprior = prior_logdens_transf(param_to_transf(the_param));
            optim_logpost(i_optim) = the_loglike + the_logprior;
        catch ME
            disp('Error encountered. Message:');
            disp(ME.message);
        end
    
        % Print progress
        fprintf('%s%6d%s%6d\n\n', 'Progress: ', i_optim, '/', optim_numgrid);
        
    end
    
    % Find maximum of log posterior on grid
    [~,optim_maxind] = max(optim_logpost);
    optim_maxparam = optim_grid(optim_maxind,:);
    
    fprintf(['%s' repmat('%6.4f ',1,length(optim_maxparam)),'%s\n'], 'approximate mode  [rrhoProd,ssigmaProd] = [',...
        optim_maxparam,']');

end



%% MCMC

% Initial draw
if is_optimize
    curr_draw = param_to_transf(optim_maxparam);  % Start at approximate mode
else
    curr_draw = prior_init_transf();    % Draw from prior
end

accepts = zeros(mcmc_num_iter,1);

mcmc_num_draws = floor(mcmc_num_iter/mcmc_thin); % Number of stored draws
post_draws = nan(mcmc_num_draws,length(curr_draw));

curr_logpost = -Inf;
loglikes_prop = nan(mcmc_num_draws,1);
loglikes_prop_macro = nan(mcmc_num_draws,1);
loglikes_prop_micro = nan(mcmc_num_draws,1);

the_stepsize = mcmc_stepsize_init;      % Initial RWMH step size
the_stepsize_iter = 1;
the_chol = eye(length(curr_draw));      % Initial RWMH proposal var-cov matrix

disp('MCMC...');
timer_mcmc = tic;

for i_mcmc=1:mcmc_num_iter % For each MCMC step...
    
    fprintf(['%s' repmat('%6.4f ',1,length(curr_draw)),'%s\n'], 'current  [rrhoProd,ssigmaProd] = [',...
        transf_to_param(curr_draw),']');
    
    % Proposed draw (modified to always start with initial draw)
    prop_draw = rwmh_propose(curr_draw, (i_mcmc>1)*the_stepsize, the_chol); % Proposal
    
    % Set new parameters
    the_transf = num2cell(transf_to_param(prop_draw));
    [rrhoProd,ssigmaProd] = deal(the_transf{:});

    fprintf(['%s' repmat('%6.4f ',1,length(curr_draw)),'%s\n'], 'proposed [rrhoProd,ssigmaProd] = [',...
        [rrhoProd,ssigmaProd],']');
    
    try
        
        [the_loglike_prop, the_loglike_prop_macro, the_loglike_prop_micro] = ...
         aux_compute_likel(simul_data_micro, ts_micro, ...
                                   num_smooth_draws, trunc_logn, num_burnin_periods, ...
                                   M_, oo_, options_, ...
                                   likelihood_type);
        
        % Log prior density of proposal
        logprior_prop = prior_logdens_transf(prop_draw);

        % Accept/reject
        [curr_draw, curr_logpost, accepts(i_mcmc), the_log_ar] = rwmh_accrej(curr_draw, prop_draw, curr_logpost, logprior_prop+the_loglike_prop);

        % Adapt proposal step size
        [the_stepsize, the_stepsize_iter] = adapt_stepsize(the_stepsize, the_stepsize_iter, i_mcmc, the_log_ar, mcmc_c, mcmc_ar_tg);
    
    catch ME
        
        disp('Error encountered. Message:');
        disp(ME.message);
        
        the_loglike_prop = nan;
        the_loglike_prop_macro = nan;
        the_loglike_prop_micro = nan;
        
    end
    
    % Store (with thinning)
    if mod(i_mcmc, mcmc_thin)==0
        post_draws(i_mcmc/mcmc_thin,:) = transf_to_param(curr_draw);
        loglikes_prop(i_mcmc/mcmc_thin) = the_loglike_prop;
        loglikes_prop_macro(i_mcmc/mcmc_thin) = the_loglike_prop_macro;
        loglikes_prop_micro(i_mcmc/mcmc_thin) = the_loglike_prop_micro;
    end
    
    % Print acceptance rate
    fprintf('%s%5.1f%s\n', 'Accept. rate last 100: ', 100*mean(accepts(max(i_mcmc-99,1):i_mcmc)), '%');
    fprintf('%s%6d%s%6d\n\n', 'Progress: ', i_mcmc, '/', mcmc_num_iter);
    
    % Adapt proposal covariance matrix
    [the_chol, the_stepsize_iter] = adapt_cov(the_chol, the_stepsize_iter, mcmc_adapt_iter, i_mcmc, post_draws, mcmc_thin, mcmc_adapt_diag, mcmc_adapt_param);
    
end

delete(poolobj);

mcmc_elapsed = toc(timer_mcmc);
fprintf('%s%8.2f\n', 'MCMC done. Elapsed minutes: ', mcmc_elapsed/60);

cd('../../');

save(mcmc_filename);
rmpath('auxiliary_functions/dynare', 'auxiliary_functions/likelihood', 'auxiliary_functions/sim');


%% Auxiliary function

function [the_loglike, the_loglike_macro, the_loglike_micro] = ...
         aux_compute_likel(simul_data_micro, ts_micro, ...
                                   num_smooth_draws, trunc_logn, num_burnin_periods, ...
                                   M_, oo_, options_, ...
                                   likelihood_type)

        saveParameters;         % Save parameter values to files
        setDynareParameters;    % Update Dynare parameters in model struct
        compute_steady_state;   % Compute steady state, no need for parameters of agg dynamics
        compute_meas_err;       % Update measurement error var-cov matrix

        % Log likelihood of proposal
        switch likelihood_type
            case 1 % Macro + full info micro
                [the_loglike, the_loglike_macro, the_loglike_micro] = ...
                    loglike_compute('simul.mat', simul_data_micro, ts_micro, ...
                                   num_smooth_draws, trunc_logn, num_burnin_periods, ...
                                   M_, oo_, options_);
            case 2 % Macro + full info micro, ignore truncation
                [the_loglike, the_loglike_macro, the_loglike_micro] = ...
                    loglike_compute('simul.mat', simul_data_micro, ts_micro, ...
                                   num_smooth_draws, -Inf, num_burnin_periods, ...
                                   M_, oo_, options_);
            case 3 % Macro + moments w/ SS meas. err.
                [the_loglike, the_loglike_macro, the_loglike_micro] = ...
                    loglike_compute('simul_moments.mat', [], ts_micro, ...
                                   0, [], num_burnin_periods, ...
                                   M_, oo_, options_);
        end
        
end
function [post nlZ dnlZ] = infKLprox(hyp, mean, cov, lik, x, y)
% KL-Proximal Variational Gaussian Inference 
% TODO Adding calcularion of nlZ, dnlZ
% TODO step-size setting (also including decreasing sequence of step-size)
% TODO make it work with any likelihood function using quadrature.
%
% Copyright (c) by Emtiyaz Khan and Hannes Nickisch 2015-06-4.

% some algorithmic parameters
out = false;%true;
tol = 1e-4;                                              % convergence threshold
kmax = 2000;                                      % maximum number of iterations

% GP prior
n = size(x,1);
K = feval(cov{:}, hyp.cov, x);                  % evaluate the covariance matrix
m = feval(mean{:}, hyp.mean, x);                      % evaluate the mean vector

% initialize using GP reg
tW = 1*ones(n,1);
L = chol(K+eye(n));
T = L'\K;
post_v = diag(K) - sum(T.*T,1)'; % v = diag(inv(inv(K)+diag(W)));
post_m = K*(L\(L'\y));

% simple initialization
%tW = 1*ones(n,1);
%post_m = m;
%post_v = diag(K);

% For testing: initialize using EP to check convergence
%[post] = infEP(hyp, mean, cov, lik, x, y);
%sW = post.sW; L = post.L; al = post.alpha;
%post_m = m + K*al;
%T = L'\(repmat(sW,1,n).*K); %T  = L'\(sW*K);
%post_v = diag(K) - sum(T.*T,1)'; % v = diag(inv(inv(K)+diag(W)));
%tW = 1*ones(n,1);

% Change the lik function. I have to use my own lik function 
% since for inbuilt function in GPML, prox doesn't converge.
% But my function only works for likLogistic and likLaplace
lik = func2str(lik{1});

% set beta
switch lik
case 'likLogistic'
  beta_fixed = 0.24;
case 'likLaplace'
  beta_fixed = 0.99;
otherwise
  beta_fixed = 0.1;
end

% iterate
for k = 1:kmax                                                         % iterate
  % step size
  beta = beta_fixed;
  r = 1/(beta+1);
  
  % lik query
  %[ll,df,d2f,dv] = likKL(post_v, lik, hyp.lik, y, post_m); al = df; W = -2*dv; 
  [ll, df, dv] = E_log_p(lik, y, post_m, post_v, hyp.lik); al = df; W = -2*dv;
  
  % pseudo observation
  pseudo_y = m + K*al - post_m;
  sW = sqrt(r.*tW); % noise sd
  
  % test convergence using gradient of ELBO
  grad = pseudo_y'*pseudo_y + 0.5*sum(abs(tW(:) - W(:)));
  if out; fprintf('%d) %.4f \n', k, grad); end;
  if grad<tol; break; end;
  
  % GP reg predictive mean and variance
  L = chol(eye(n)+sW*sW'.*K); %L = chol(sW*K*sW + eye(n)); 
  post_m = post_m + (1-r)*(pseudo_y - K*(sW.*( L\ (L'\(sW.*pseudo_y)))));
  T = L'\(repmat(sW,1,n).*K); %T  = L'\(sW*K);
  post_v = diag(K) - sum(T.*T,1)'; % v = diag(inv(inv(K)+diag(W)));
  tW = r*tW + (1-r)*W;
end
if k==kmax, warning('max number of iterations reached.'), end;

post.sW = sW;                                             % return argument
post.alpha = al;
post.L = L;                                              % L'*L=B=eye(n)+sW*K*sW

if nargout>1
  warning('to be implemented\n');
  nlZ = NaN; dnlZ = NaN;
  %{
  A = (eye(n)+ones(n,1)*W'.*K)\eye(n);                            % A = V*inv(K)
  % lower bound on negative log marginal likelihood
  nlZ = -sum(ll) + sum(log(diag(L))) + (al'*K*al+trace(A)-n)/2;
  if nargout>2                                         % do we want derivatives?
    dnlZ = hyp;                                 % allocate space for derivatives
    for j=1:length(hyp.cov)                                  % covariance hypers
      dK = feval(cov{:},hyp.cov,x,[],j); AdK = A*dK;
      z = diag(AdK) + sum(A.*AdK,2) - sum(A'.*AdK,1)';
      dnlZ.cov(j) = al'*dK*(al/2-df) - z'*dv;
    end
    for j=1:length(hyp.lik)                                  % likelihood hypers
      lp_dhyp = likKL(v,lik,hyp.lik,y,f,[],[],j);
      dnlZ.lik(j) = -sum(lp_dhyp);
    end
    for j=1:length(hyp.mean)                                       % mean hypers
      dm = feval(mean{:}, hyp.mean, x, j);
      dnlZ.mean(j) = -al'*dm;
    end
  end
  %}
end

% Gaussian smoothed likelihood function; instead of p(y|f)=lik(..,f,..) compute
%   log likKL(f) = int log lik(..,t,..) N(f|t,v) dt, where
%     v   .. marginal variance = (positive) smoothing width, and
%     lik .. lik function such that feval(lik{:},varargin{:}) yields a result.
% All return values are separately integrated using Gaussian-Hermite quadrature.
function [ll,df,d2f,dv,d2v,dfdv] = likKL(v, lik, varargin)
  f = varargin{3};                               % obtain location of evaluation
  sv = sqrt(v);                                                % smoothing width
  lik_str = lik{1}; if ~ischar(lik_str), lik_str = func2str(lik_str); end
  if strcmp(lik_str,'likLaplace')          % likLaplace can be done analytically
    b = exp(varargin{1})/sqrt(2); y = varargin{2};
    mu = (f-y)/b; z = (f-y)./sv;
    Nz = exp(-z.^2/2)/sqrt(2*pi);
    Cz = (1+erf(z/sqrt(2)))/2;
    ll = (1-2*Cz).*mu - 2/b*sv.*Nz - log(2*b);
    df = (1-2*Cz)/b;
    d2f = -2*Nz./(b*(sv+eps));
    dv = d2f/2;
    d2v = (z.*z-1)./(v+eps).*d2f/4;
    dfdv = -z.*d2f./(2*sv+eps);
  else
    N = 20;                                        % number of quadrature points
    [t,w] = gauher(N);    % location and weights for Gaussian-Hermite quadrature
    ll = 0; df = 0; d2f = 0; dv = 0; d2v = 0; dfdv = 0;  % init return arguments
    for i=1:N                                          % use Gaussian quadrature
      varargin{3} = f + sv*t(i); % coordinate transform of the quadrature points
      [lp,dlp,d2lp]=feval(lik{:},varargin{1:3},[],'infLaplace',varargin{6:end});
      ll   = ll  + w(i)*lp;                              % value of the integral
      df   = df  + w(i)*dlp;                              % derivative wrt. mean
      d2f  = d2f + w(i)*d2lp;                         % 2nd derivative wrt. mean
      ai = t(i)./(2*sv+eps); dvi = dlp.*ai; dv = dv+w(i)*dvi;   % deriv wrt. var
      d2v  = d2v + w(i)*(d2lp.*(t(i)^2/2)-dvi)./(v+eps)/2;  % 2nd deriv wrt. var
      dfdv = dfdv + w(i)*(ai.*d2lp);                  % mixed second derivatives
    end
  end
  
function [f, gm, gv] = E_log_p(name, y, m, v, params)
% This function computes E( log p(y|x) ) where 
% expectation is wrt p(x) = N(x|m,v) with mean m and variance v.
% params are optional parameters required for approximation
%
% Written by Emtiyaz, EPFL
% Modified on March 18, 2015

  % vectorize all variables
  y = y(:); m = m(:); v = v(:);

  switch name
  case {'laplace','likLaplace'}
    b = 2*exp(params)/sqrt(2); % according to gpml-toolbox's likLaplace
    sigma = sqrt(v);
    m1 = (y - m)./sigma;
    phi = normpdf(m1);
    Phi = normcdf(m1);
    f = -(sigma./b).*( 2*phi + m1.*(2*Phi - 1) );
    gm = (2*Phi -1)/b;
    gsigma = -2*phi/b;
    gv = gsigma./(2*sigma);

  case 'poisson'
    % log p(y|x) = y*x - e^x where y is non-negative integer
    t = exp(m+v/2);
    f = y.*m - t;
    gm = y - t;
    gv = -t/2;

  case {'bernoulli_logit','likLogistic'}
    if ~isempty(y==-1)
      y = (y+1)/2;
    end
    % log p(y|x) = y*x - log(1+exp(x) where y is 0 or 1
    % Based on "Piecewise Bounds for Estimating ...
    % Bernoulli-Logistic Latent Gaussian Models", ICML 2011
    llp_bound = get_llp_bound(); % approx to log(1+exp(x))
    [t, gm, gv] = Ellp(m, v, llp_bound, [1 1 1]);
    f = y.*m - t;
    gm = y - gm;
    gv = -gv;

  otherwise
    error('no such name');
  end

function [f, gm, gv] = Ellp(m, v, bound, ind)
% compute piecewise bound to E(log(1+exp(x))) where x~N(m,v)
% Here, m and v can be vectors
% bound need to be a matrix, can be obtained by loading llp.mat
% ind is 3x1 vector specifying which outputs to compute
% Example:
% [f2, gm2, gv2] = funObj_pw_new(m, v, bound, [1 1 1]);
% see the appendix
% http://www.cs.ubc.ca/~emtiyaz/papers/truncatedGaussianMoments.pdf
% for detailed expressions
%
% Written by Emtiyaz, CS, UBC
% Modifiied on May 26, 2012


if(v<=0)
  error('Normal variance must be strictly positive');
end

% get piecewise bound parameters
% (a,b,c) are parameters for quadratic pieces and (l,h) are lower and upper limit of each piece
c = bound(1,:)';
b = bound(2,:)';
a = bound(3,:)';
l = bound(4,:)';
h = bound(5,:)';

m = m(:)';
v = v(:)';

% compute pdf and cdfs
zl = bsxfun(@times, bsxfun(@minus,l,m), 1./sqrt(v));
zh = bsxfun(@times, bsxfun(@minus,h,m), 1./sqrt(v));

pl = bsxfun(@times, normpdf(zl), 1./sqrt(v)); %normal pdf
ph = bsxfun(@times, normpdf(zh), 1./sqrt(v)); %normal pdf
cl = 0.5*erf(zl/sqrt(2)); %normal cdf -const
ch = 0.5*erf(zh/sqrt(2)); %normal cdf -cosnt

% zero out the inf and -inf in l and h
l(1) = 0; 
h(end) = 0; 

f = 0;
gm = 0;
gv = 0;
% compute function value
if ind(1)
  %Compute truncated zeroth moment
  ex0 = ch-cl;
  %Compute truncated first moment
  %ex1= v.*(pl-ph) + m.*(ch-cl);
  ex1= bsxfun(@times, v, (pl-ph)) + bsxfun(@times, m,(ch-cl));
  %Compute truncated second moment
  %ex2=  v.*((l+m).*pl - (h+m).*ph) + (v+m.^2).*(ch - cl);
  ex2 = bsxfun(@times, v, (bsxfun(@plus, l, m)).*pl - (bsxfun(@plus, h, m)).*ph) ... 
  + bsxfun(@times, (v+m.^2), (ch-cl));
  % compute f
  %fr = a.*ex2 + b.*ex1 + c.*ex0;
  fr = bsxfun(@times, a, ex2) + bsxfun(@times, b, ex1) + bsxfun(@times, c, ex0); 
  f = sum(fr,1)';
end

%Compute Gradient wrt to mean
if ind(2)
  %gm = a.*( (l.^2+2*v).*pl - (h.^2+2*v).*ph) + a.*2.*m.*(ch-cl); 
  gm = bsxfun(@times, a, bsxfun(@plus, l.^2, 2*v).*pl - bsxfun(@plus, h.^2, 2*v).*ph)...
+ 2*bsxfun(@times, a, m).*(ch - cl);
  %gm = gm + b.*(l.*pl-h.*ph) + b.*(ch-cl);
  gm = gm + bsxfun(@times, b, bsxfun(@times, l, pl) - bsxfun(@times, h, ph))...
          + bsxfun(@times, b, ch-cl);
  %gm = gm + c.*(pl-ph);
  gm = gm + bsxfun(@times, c, pl-ph);
  gm = sum(gm,1)';
end

%Compute Gradient wrt to variance
if ind(3)
  
  t1 = bsxfun(@plus, 2*bsxfun(@times, v, l), l.^3) - bsxfun(@times, l.^2, m);
  t2 = bsxfun(@plus, 2*bsxfun(@times, v, h), h.^3) - bsxfun(@times, h.^2, m);
  gv = bsxfun(@times, a/2, 1./v).*(t1.*pl - t2.*ph) + bsxfun(@times, a, ch-cl);

  gv = gv + bsxfun(@times, b/2, 1./v).*...
      ((bsxfun(@plus, l.^2, v) - bsxfun(@times, l, m)).*pl ... 
      - (bsxfun(@plus, h.^2, v) - bsxfun(@times, h, m)).*ph);

  gv = gv + bsxfun(@times, c/2, 1./v).*...
          ((bsxfun(@minus,l,m)).*pl - (bsxfun(@minus,h,m)).*ph);

  %gv = a/2./v.*( (2*v*l + l.^3 -l.^2*m).*pl - (2*v*h + h.^3 -h.^2*m).*ph) +a.*(ch-cl);
  %gv = gv + b/2./v.*( (l.^2+v-l*m).*pl - (h.^2+v-h*m).*ph); 
  %gv = gv + c/2./v.*((l-m).*pl-(h-m).*ph);
  gv = sum(gv,1)';
end

if length(ind) == 4
    if ind(4)
      
      hm = bsxfun(@times, a, bsxfun(@times, 1./v, bsxfun(@plus, l.^3, -l.^2*m + 2*l*v).*pl - bsxfun(@plus, h.^3, -h.^2*m + 2*h*v).*ph) ...
          + 2.*(ch - cl));
        
      hm = hm + bsxfun(@times, b, bsxfun(@times, 1./v, bsxfun(@minus, l.^2, l*m).*pl - bsxfun(@minus, h.^2, h*m).*ph) ...
          + (pl - ph));
      
      hm = hm + bsxfun(@times, c, 1./v).*...
          ((bsxfun(@minus,l,m)).*pl - (bsxfun(@minus,h,m)).*ph);
      
      hm = sum(hm,1)';
      
      % gh = c./v.*((l-m).*pl-(h-m).*ph);
      % gh = gh +  b.*((1/v.*(l^2 - l*m).*pl - (h^2 -h*m).*ph) + pl - ph) 
    end;
end;

function bound = get_llp_bound()
% hard coded 

	bound(:,1:5) = ...
   [0.000188712193000   0.028090310300000   0.110211757000000   0.232736440000000   0.372524706000000;
                   0   0.006648614600000   0.034432684600000   0.088701969900000   0.168024214000000;
                   0   0.000397791059000   0.002753100850000   0.008770186980000   0.020034759300000;
                -Inf  -8.575194939999999  -5.933689180000000  -4.525933600000000  -3.528107790000000;
  -8.575194939999999  -5.933689180000000  -4.525933600000000  -3.528107790000000  -2.751548540000000];

	bound(:,6:10) = ...
   [0.504567936000000   0.606280283000000   0.666125432000000   0.689334264000000   0.693147181000000;
   0.264032863000000   0.360755794000000   0.439094482000000   0.485091758000000   0.499419205000000;
   0.037511596000000   0.060543032900000   0.086256780600000   0.109213531000000   0.123026104000000;
  -2.751548540000000  -2.097898790000000  -1.519690830000000  -0.989533382000000  -0.491473077000000;
  -2.097898790000000  -1.519690830000000  -0.989533382000000  -0.491473077000000                   0];

	bound(:,11:15) = ...
   [0.693147181000000   0.689334264000000   0.666125432000000   0.606280283000000   0.504567936000000;
   0.500580795000000   0.514908242000000   0.560905518000000   0.639244206000000   0.735967137000000;
   0.123026104000000   0.109213531000000   0.086256780600000   0.060543032900000   0.037511596000000;
                   0   0.491473077000000   0.989533382000000   1.519690830000000   2.097898790000000;
   0.491473077000000   0.989533382000000   1.519690830000000   2.097898790000000   2.751548540000000];

	bound(:,16:20) = ...
   [0.372524706000000   0.232736440000000   0.110211757000000   0.028090310400000   0.000188712000000;
   0.831975786000000   0.911298030000000   0.965567315000000   0.993351385000000   1.000000000000000;
   0.020034759300000   0.008770186980000   0.002753100850000   0.000397791059000                   0;
   2.751548540000000   3.528107790000000   4.525933600000000   5.933689180000000   8.575194939999999;
   3.528107790000000   4.525933600000000   5.933689180000000   8.575194939999999                 Inf];


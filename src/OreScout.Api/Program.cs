using Microsoft.EntityFrameworkCore;
using Npgsql;
using OreScout.Api.Data;
using OreScout.Api.Endpoints;
using OreScout.Api.Middleware;
using OreScout.Api.Services;

var builder = WebApplication.CreateBuilder(args);

var connString = builder.Configuration.GetConnectionString("Postgres")
    ?? throw new InvalidOperationException("ConnectionStrings:Postgres is not configured.");

// ---- Services --------------------------------------------------------------
builder.Services.AddOpenApi();

// EF Core owns public.pins (§6.11).
builder.Services.AddDbContext<OreScoutDbContext>(o => o.UseNpgsql(connString));

// Raw data source for the assessment/health/meta queries (PostGIS functions).
builder.Services.AddSingleton(NpgsqlDataSource.Create(connString));

builder.Services.AddScoped<IAssessmentService, AssessmentService>();

// Live BLM MLRS claims check (typed HttpClient; per-request 10s timeout in the service).
builder.Services.AddHttpClient<IClaimsService, MlrsClaimsService>(http =>
    http.DefaultRequestHeaders.UserAgent.ParseAdd("OreScout/0.1"));

// Typed HttpClient for the Nominatim proxy — single egress point, descriptive UA (§6.2).
builder.Services.AddHttpClient<IGeocoder, NominatimGeocoder>((sp, http) =>
{
    var cfg = sp.GetRequiredService<IConfiguration>();
    http.BaseAddress = new Uri(cfg["Nominatim:BaseUrl"] ?? "https://nominatim.openstreetmap.org");
    http.DefaultRequestHeaders.UserAgent.ParseAdd(cfg["Nominatim:UserAgent"] ?? "OreScout/0.1");
    http.Timeout = TimeSpan.FromSeconds(10);
});
builder.Services.AddHttpClient(); // default client (tileserv health probe)

// CORS — explicit allow-list, never wildcard (§6.2).
var origins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
builder.Services.AddCors(o => o.AddDefaultPolicy(p =>
    p.WithOrigins(origins).AllowAnyHeader().AllowAnyMethod()));

var app = builder.Build();

// ---- Pipeline --------------------------------------------------------------
if (app.Environment.IsDevelopment())
    app.MapOpenApi();

app.UseCors();
app.UseMiddleware<ApiKeyMiddleware>();

app.MapApiV1();

app.Run();

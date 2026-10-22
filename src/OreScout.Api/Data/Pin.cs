namespace OreScout.Api.Data;

/// <summary>
/// A saved location (docs/planning/PROJECT_PLAN.md §4.2 / §6.5). Owned by EF Core migrations.
/// The `geom` generated column, GIST/GIN indexes, and updated_at trigger are added
/// as raw SQL in the migration (they are DB-side concerns EF doesn't model directly).
/// </summary>
public class Pin
{
    public Guid Id { get; set; }
    public double Lat { get; set; }
    public double Lng { get; set; }
    public string Title { get; set; } = null!;
    public string? Notes { get; set; }

    /// <summary>'want_to_visit' | 'visited' (CHECK constraint in the migration).</summary>
    public string Status { get; set; } = "want_to_visit";

    /// <summary>System-generated in MVP; user-custom in future. Stored as text[].</summary>
    public string[] Tags { get; set; } = Array.Empty<string>();

    /// <summary>Full canonical /assessment response captured at save time (jsonb).</summary>
    public string? AssessmentSnapshot { get; set; }

    public DateTimeOffset? AssessmentDate { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

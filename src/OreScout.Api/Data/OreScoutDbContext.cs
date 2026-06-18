using Microsoft.EntityFrameworkCore;

namespace OreScout.Api.Data;

public class OreScoutDbContext(DbContextOptions<OreScoutDbContext> options) : DbContext(options)
{
    public DbSet<Pin> Pins => Set<Pin>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        var pin = b.Entity<Pin>();
        pin.ToTable("pins", schema: "public");
        pin.HasKey(p => p.Id);

        pin.Property(p => p.Id).HasColumnName("id").HasDefaultValueSql("gen_random_uuid()");
        pin.Property(p => p.Lat).HasColumnName("lat");
        pin.Property(p => p.Lng).HasColumnName("lng");
        pin.Property(p => p.Title).HasColumnName("title").HasMaxLength(200).IsRequired();
        pin.Property(p => p.Notes).HasColumnName("notes");
        pin.Property(p => p.Status).HasColumnName("status").HasMaxLength(20).HasDefaultValue("want_to_visit");
        pin.Property(p => p.Tags).HasColumnName("tags").HasColumnType("text[]").HasDefaultValueSql("'{}'");
        pin.Property(p => p.AssessmentSnapshot).HasColumnName("assessment_snapshot").HasColumnType("jsonb");
        pin.Property(p => p.AssessmentDate).HasColumnName("assessment_date");
        pin.Property(p => p.CreatedAt).HasColumnName("created_at").HasDefaultValueSql("now()");
        pin.Property(p => p.UpdatedAt).HasColumnName("updated_at").HasDefaultValueSql("now()");

        // status CHECK — the generated `geom` column, GIST/GIN indexes, and the
        // updated_at trigger are added as raw SQL in the migration (see Migrations/).
        pin.ToTable(t => t.HasCheckConstraint("ck_pins_status", "status IN ('want_to_visit','visited')"));
    }
}

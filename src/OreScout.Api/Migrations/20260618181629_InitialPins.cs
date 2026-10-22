using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace OreScout.Api.Migrations
{
    /// <inheritdoc />
    public partial class InitialPins : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.EnsureSchema(
                name: "public");

            migrationBuilder.CreateTable(
                name: "pins",
                schema: "public",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false, defaultValueSql: "gen_random_uuid()"),
                    lat = table.Column<double>(type: "double precision", nullable: false),
                    lng = table.Column<double>(type: "double precision", nullable: false),
                    title = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                    notes = table.Column<string>(type: "text", nullable: true),
                    status = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false, defaultValue: "want_to_visit"),
                    tags = table.Column<string[]>(type: "text[]", nullable: false, defaultValueSql: "'{}'"),
                    assessment_snapshot = table.Column<string>(type: "jsonb", nullable: true),
                    assessment_date = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false, defaultValueSql: "now()"),
                    updated_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false, defaultValueSql: "now()")
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_pins", x => x.id);
                    table.CheckConstraint("ck_pins_status", "status IN ('want_to_visit','visited')");
                });

            // DB-side concerns EF doesn't model directly (docs/planning/PROJECT_PLAN.md §6.5):
            // a generated geometry column, spatial/tag indexes, and the updated_at trigger.
            migrationBuilder.Sql("""
                ALTER TABLE public.pins
                  ADD COLUMN geom geometry(Point, 4326)
                  GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(lng, lat), 4326)) STORED;
                """);
            migrationBuilder.Sql("CREATE INDEX pins_geom_idx ON public.pins USING GIST (geom);");
            migrationBuilder.Sql("CREATE INDEX pins_tags_idx ON public.pins USING GIN (tags);");
            migrationBuilder.Sql("""
                CREATE OR REPLACE FUNCTION public.update_updated_at()
                RETURNS TRIGGER AS $$
                BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
                $$ LANGUAGE plpgsql;
                """);
            migrationBuilder.Sql("""
                CREATE TRIGGER pins_updated_at
                  BEFORE UPDATE ON public.pins
                  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "pins",
                schema: "public");
            migrationBuilder.Sql("DROP FUNCTION IF EXISTS public.update_updated_at();");
        }
    }
}

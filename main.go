package main

import (
	"context"
	"fmt"
	"log"
	"maps"
	"os"
	"strings"

	"github.com/blang/semver/v4"
	"github.com/operator-framework/operator-registry/alpha/declcfg"
	"github.com/operator-framework/operator-registry/alpha/model"
	"github.com/spf13/pflag"
	"k8s.io/apimachinery/pkg/util/sets"
)

type Graph struct {
	Self       *model.Bundle
	Successors map[string]*model.Bundle
}

func main() {
	catalogsDir := pflag.String("catalogs-dir", "catalogs/incident", "path to the catalogs directory (used for incident comparison in steps 1-2)")
	recentCatalogsDir := pflag.String("recent-catalogs-dir", "catalogs/latest", "path to recent catalogs directory (used for step 3 update edge check); defaults to --catalogs-dir if not set")
	fromVersions := pflag.StringSlice("from", []string{"4.12", "4.13", "4.14", "4.15", "4.16", "4.17"}, "list of OCP versions to evaluate")
	toVersion := pflag.String("to", "4.18", "target catalog providing update edges")
	pflag.Parse()

	if *recentCatalogsDir == "" {
		*recentCatalogsDir = *catalogsDir
	}

	if err := run(*catalogsDir, *recentCatalogsDir, *fromVersions, *toVersion); err != nil {
		log.Fatal(err)
	}
}

func run(catalogsDir, recentCatalogsDir string, fromVersions []string, toVersion string) error {
	toDir := fmt.Sprintf("%s/%s", catalogsDir, toVersion)
	toFBC, err := declcfg.LoadFS(context.Background(), os.DirFS(toDir))
	if err != nil {
		return fmt.Errorf("loading catalog %q: %w", toDir, err)
	}
	toModel, err := declcfg.ConvertToModel(*toFBC)
	if err != nil {
		return fmt.Errorf("converting catalog %q to model: %w", toDir, err)
	}

	for _, fromVersion := range fromVersions {
		fromDir := fmt.Sprintf("%s/%s", catalogsDir, fromVersion)
		fromFBC, err := declcfg.LoadFS(context.Background(), os.DirFS(fromDir))
		if err != nil {
			return fmt.Errorf("loading catalog %q: %w", fromDir, err)
		}
		fromModel, err := declcfg.ConvertToModel(*fromFBC)
		if err != nil {
			return fmt.Errorf("converting catalog %q to model: %w", fromDir, err)
		}

		recentFromDir := fmt.Sprintf("%s/%s", recentCatalogsDir, fromVersion)
		recentFromFBC, err := declcfg.LoadFS(context.Background(), os.DirFS(recentFromDir))
		if err != nil {
			return fmt.Errorf("loading recent catalog %q: %w", recentFromDir, err)
		}
		recentFromModel, err := declcfg.ConvertToModel(*recentFromFBC)
		if err != nil {
			return fmt.Errorf("converting recent catalog %q to model: %w", recentFromDir, err)
		}

		compareVersions(fromVersion, toVersion, fromModel, recentFromModel, toModel)
	}

	return nil
}

type ProblemPackage struct {
	OCPVersion   string       `json:"ocpVersion"`
	PackageName  string       `json:"packageName"`
	DisplayNames []string     `json:"displayNames"`
	CSVs         []ProblemCSV `json:"csvs"`
}

type ProblemCSV struct {
	Name                          string         `json:"name"`
	Version                       semver.Version `json:"version"`
	IncidentCatalogMemberChannels []string       `json:"incidentCatalogMemberChannels"`
	OriginalCatalogUpdateChannels []string       `json:"originalCatalogUpdateChannels"`
}

func compareVersions(fromVersion, toVersion string, from, recentFrom, to model.Model) {
	for _, fromPkg := range from {
		toPkg, ok := to[fromPkg.Name]
		if !ok {
			continue
		}

		displayNames := sets.New[string]()

		fromBundles := map[string]semver.Version{}
		toBundles := map[string]semver.Version{}
		for _, ch := range fromPkg.Channels {
			for _, b := range ch.Bundles {
				fromBundles[b.Name] = b.Version
			}
		}
		for _, ch := range toPkg.Channels {
			for _, b := range ch.Bundles {
				toBundles[b.Name] = b.Version
				displayNames.Insert(b.PropertiesP.CSVMetadatas[0].DisplayName)
			}
		}
		onlyInTo := maps.Clone(toBundles)
		for k := range fromBundles {
			delete(onlyInTo, k)
		}

		fromEntries := map[string][]declcfg.ChannelEntry{}
		for _, ch := range fromPkg.Channels {
			for _, b := range ch.Bundles {
				fromEntries[b.Name] = append(fromEntries[b.Name], declcfg.ChannelEntry{
					Name: b.Name, Replaces: b.Replaces, Skips: b.Skips, SkipRange: b.SkipRange,
				})
			}
		}

		type channelEntry struct {
			ChannelName string
			declcfg.ChannelEntry
		}

		toEntries := map[string][]channelEntry{}
		for _, ch := range toPkg.Channels {
			for _, b := range ch.Bundles {
				toEntries[b.Name] = append(toEntries[b.Name], channelEntry{
					ChannelName: ch.Name,
					ChannelEntry: declcfg.ChannelEntry{
						Name: b.Name, Replaces: b.Replaces, Skips: b.Skips, SkipRange: b.SkipRange,
					},
				})
			}
		}
		hasEdgeFrom := func(toName string, fromVersions map[string]semver.Version, entries map[string][]channelEntry) bool {
			for _, e := range toEntries[toName] {
				skips := sets.New[string](e.Skips...)
				sr := func(semver.Version) bool { return false }
				if e.SkipRange != "" {
					if parsed, err := semver.ParseRange(e.SkipRange); err == nil {
						sr = parsed
					} else {
						fmt.Fprintf(os.Stderr, "WARNING: SkipRange %q for bundle %q is not a valid semver range: %v\n", e.SkipRange, e.Name, err)
					}
				}
				for name, ver := range fromVersions {
					if e.Replaces == name || skips.Has(name) || sr(ver) {
						return true
					}
				}
			}
			return false
		}

		// First we'll build the set of bundles that are in the "onlyInTo" map that also have an upgrade edge from any bundle in "fromBundles"
		reachable := map[string]semver.Version{}
		for bName, bVer := range onlyInTo {
			if hasEdgeFrom(bName, fromBundles, toEntries) {
				reachable[bName] = bVer
			}
		}

		// Then, we iterate over the "onlyInTo" map, again and again, looking for more bundles that have upgrade edges from any bundle already in the set.
		// We'll only stop iterating when an iteration does not find further bundles to add to the set.
		for {
			changed := false
			for bName, bVer := range onlyInTo {
				if _, ok := reachable[bName]; ok {
					continue
				}
				if hasEdgeFrom(bName, reachable, toEntries) {
					reachable[bName] = bVer
					changed = true
				}
			}
			if !changed {
				break
			}
		}

		if len(reachable) == 0 {
			continue
		}
		problemCSVs := []ProblemCSV{}
		for name, ver := range reachable {
			incidentChannels := sets.New[string]()
			for _, ce := range toEntries[name] {
				incidentChannels.Insert(ce.ChannelName)
			}
			problemCSVs = append(problemCSVs, ProblemCSV{Name: name, Version: ver, IncidentCatalogMemberChannels: sets.List(incidentChannels)})
		}
		problemPackage := ProblemPackage{
			OCPVersion:   fromVersion,
			PackageName:  toPkg.Name,
			DisplayNames: sets.List(displayNames),
			CSVs:         problemCSVs,
		}

		// For each problem CSV, go back to the recent from-catalog and find all channel names that contain entries that can update from that problem CSV.
		if recentFromPkg, ok := recentFrom[fromPkg.Name]; ok {
			for i, pc := range problemPackage.CSVs {
				channelNames := sets.New[string]()
				for _, fromCh := range recentFromPkg.Channels {
					for _, fromBundle := range fromCh.Bundles {
						skips := sets.New[string](fromBundle.Skips...)
						sr := func(semver.Version) bool { return false }
						if fromBundle.SkipRange != "" {
							if parsed, err := semver.ParseRange(fromBundle.SkipRange); err == nil {
								sr = parsed
							} else {
								fmt.Fprintf(os.Stderr, "WARNING: SkipRange %q is not a valid semver range: %v\n", fromBundle.SkipRange, err)
							}
						}
						if fromBundle.Replaces == pc.Name || skips.Has(pc.Name) || sr(pc.Version) {
							channelNames.Insert(fromCh.Name)
						}
					}
				}
				problemPackage.CSVs[i].OriginalCatalogUpdateChannels = sets.List(channelNames)
			}
		}

		for _, csv := range problemPackage.CSVs {
			fmt.Printf("%s %s %s %q %q %v\n", problemPackage.PackageName, problemPackage.OCPVersion, csv.Name, strings.Join(csv.IncidentCatalogMemberChannels, ","), strings.Join(csv.OriginalCatalogUpdateChannels, ","), len(csv.OriginalCatalogUpdateChannels) > 0)
		}
	}
}

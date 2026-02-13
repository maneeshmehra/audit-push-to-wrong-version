package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"maps"
	"os"

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
	fromVersions := pflag.StringSlice("from", []string{"4.12", "4.13", "4.14", "4.15", "4.16", "4.17"}, "list of OCP versions to evaluate")
	toVersion := pflag.String("to", "4.18", "target catalog providing update edges")
	pflag.Parse()

	if err := run(*fromVersions, *toVersion); err != nil {
		log.Fatal(err)
	}
}

func run(fromVersions []string, toVersion string) error {
	toDir := fmt.Sprintf("catalogs/%s", toVersion)
	toFBC, err := declcfg.LoadFS(context.Background(), os.DirFS(toDir))
	if err != nil {
		return fmt.Errorf("loading catalog %q: %w", toDir, err)
	}
	toModel, err := declcfg.ConvertToModel(*toFBC)
	if err != nil {
		return fmt.Errorf("converting catalog %q to model: %w", toDir, err)
	}

	for _, fromVersion := range fromVersions {
		fromDir := fmt.Sprintf("catalogs/%s", fromVersion)
		fromFBC, err := declcfg.LoadFS(context.Background(), os.DirFS(fromDir))
		if err != nil {
			return fmt.Errorf("loading catalog %q: %w", fromDir, err)
		}
		fromModel, err := declcfg.ConvertToModel(*fromFBC)
		if err != nil {
			return fmt.Errorf("converting catalog %q to model: %w", fromDir, err)
		}
		compareVersions(fromVersion, toVersion, fromModel, toModel)
	}

	return nil
}

func compareVersions(fromVersion, toVersion string, from, to model.Model) {
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
		toEntries := map[string][]declcfg.ChannelEntry{}
		for _, ch := range toPkg.Channels {
			for _, b := range ch.Bundles {
				toEntries[b.Name] = append(toEntries[b.Name], declcfg.ChannelEntry{
					Replaces: b.Replaces, Skips: b.Skips, SkipRange: b.SkipRange,
				})
			}
		}
		hasEdgeFrom := func(bName string, sources map[string]semver.Version) bool {
			for _, e := range toEntries[bName] {
				skips := sets.New[string](e.Skips...)
				sr := func(semver.Version) bool { return false }
				if e.SkipRange != "" {
					if parsed, err := semver.ParseRange(e.SkipRange); err == nil {
						sr = parsed
					} else {
						fmt.Fprintf(os.Stderr, "WARNING: SkipRange %q is not a valid semver range: %v\n", e.SkipRange, err)
					}
				}
				for name, ver := range sources {
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
			if hasEdgeFrom(bName, fromBundles) {
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
				if hasEdgeFrom(bName, reachable) {
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
		csvNames := sets.KeySet(reachable)
		data, err := json.Marshal(struct {
			OCPVersion   string   `json:"ocpVersion"`
			PackageName  string   `json:"packageName"`
			DisplayNames []string `json:"displayNames"`
			CSVNames     []string `json:"csvNames"`
		}{
			OCPVersion:   fromVersion,
			PackageName:  toPkg.Name,
			DisplayNames: sets.List(displayNames),
			CSVNames:     sets.List(csvNames),
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "WARNING: failed to marshal JSON output row: %v\n", err)
		}
		fmt.Println(string(data))

		//for _, fromCh := range fromPkg.Channels {
		//	for _, toCh := range toPkg.Channels {
		//		for _, toBundle := range toCh.Bundles {
		//			if !onlyInTo.Has(toBundle.Name) {
		//				continue
		//			}
		//			sr := func(semver.Version) bool { return false }
		//			if toBundle.SkipRange != "" {
		//				sr, err = semver.ParseRange(toBundle.SkipRange)
		//				if err != nil {
		//					sr = func(semver.Version) bool { return false }
		//					log.Printf("WARNING: invalid skip range %q for pkg:%q, ch:%q, entry:%q", toBundle.SkipRange, toPkg.Name, toCh.Name, toBundle.Name)
		//				}
		//			}
		//
		//			for _, fromBundle := range fromCh.Bundles {
		//				if toBundle.Replaces == fromBundle.Name || sets.New[string](toBundle.Skips...).Has(fromBundle.Name) || sr(fromBundle.Version) {
		//					fmt.Println(fromVersion, fromPkg.Name, fromCh.Name, toCh.Name, fromCh.Name == toCh.Name, fromBundle.Name, toBundle.Name)
		//					continue
		//				}
		//			}
		//		}
		//	}
		//}
	}
}

// Copyright 2026 Roo Industries
// SPDX-License-Identifier: MPL-2.0

package roosyncmobile

import (
	"context"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
	"github.com/thejerf/suture/v4"
)

type session struct {
	app    *syncthing.App
	cancel context.CancelFunc
}

var (
	mu      sync.Mutex
	current *session
)

// StartCore starts the official Syncthing core with its REST API bound to loopback.
func StartCore(configDir, dataDir, defaultFolder, apiAddress, apiKey string) error {
	log.Print("RooSync core: stage=start")
	mu.Lock()
	defer mu.Unlock()
	if current != nil {
		return fmt.Errorf("Syncthing is already running")
	}
	if apiKey == "" || apiAddress == "" {
		return fmt.Errorf("REST API address and key are required")
	}
	for _, path := range []string{configDir, dataDir, defaultFolder} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			return err
		}
	}
	if err := locations.SetBaseDir(locations.ConfigBaseDir, configDir); err != nil {
		return err
	}
	if err := locations.SetBaseDir(locations.DataBaseDir, dataDir); err != nil {
		return err
	}
	if err := locations.Set(locations.DefFolder, defaultFolder); err != nil {
		return err
	}
	log.Print("RooSync core: stage=locations-ready")

	cert, err := syncthing.LoadOrGenerateCertificate(locations.Get(locations.CertFile), locations.Get(locations.KeyFile))
	if err != nil {
		return err
	}
	log.Print("RooSync core: stage=certificate-ready")

	ctx, cancel := context.WithCancel(context.Background())
	early := suture.New("early", svcutil.SpecWithDebugLogger())
	early.ServeBackground(ctx)
	evLogger := events.NewLogger()
	early.Add(evLogger)
	cfg, err := syncthing.LoadConfigAtStartup(locations.Get(locations.ConfigFile), cert, evLogger, false, true)
	if err != nil {
		cancel()
		return err
	}
	log.Print("RooSync core: stage=config-loaded")
	early.Add(cfg)
	log.Print("RooSync core: stage=config-service-added")

	log.Print("RooSync core: stage=config-modify-begin")
	waiter, err := cfg.Modify(func(c *config.Configuration) {
		c.GUI.Enabled = true
		c.GUI.RawAddress = apiAddress
		c.GUI.APIKey = apiKey
		c.GUI.RawUseTLS = false
		c.GUI.User = ""
		c.GUI.Password = ""
		c.Options.StartBrowser = false
		c.Options.URAccepted = 0
		c.Options.CREnabled = false
	})
	if err != nil {
		cancel()
		return err
	}
	log.Print("RooSync core: stage=config-modify-returned")
	waiter.Wait()
	log.Print("RooSync core: stage=config-modify-applied")

	database, err := syncthing.OpenDatabase(locations.Get(locations.Database), 365*24*time.Hour)
	if err != nil {
		cancel()
		return err
	}
	log.Print("RooSync core: stage=database-opened")
	app, err := syncthing.New(cfg, database, evLogger, cert, syncthing.Options{
		NoUpgrade:             true,
		DBMaintenanceInterval: 0,
	})
	if err != nil {
		_ = database.Close()
		cancel()
		return err
	}
	log.Print("RooSync core: stage=app-created")
	log.Print("RooSync core: stage=app-start-begin")
	if err := app.Start(); err != nil {
		_ = app.Stop(svcutil.ExitError)
		cancel()
		return err
	}
	log.Print("RooSync core: stage=api-ready")
	current = &session{app: app, cancel: cancel}
	return nil
}

// StopCore stops the embedded Syncthing core and releases its database.
func StopCore() error {
	mu.Lock()
	active := current
	current = nil
	mu.Unlock()
	if active == nil {
		return nil
	}
	active.app.Stop(svcutil.ExitSuccess)
	active.cancel()
	return active.app.Error()
}

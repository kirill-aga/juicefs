//go:build !windows && !openbsd

/*
 * JuiceFS, Copyright 2020 Juicedata, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package cmd

import (
	"os"

	"github.com/juicedata/juicefs/pkg/fuse"
	"github.com/juicedata/juicefs/pkg/utils"
	"github.com/juicedata/juicefs/pkg/vfs"
	"github.com/urfave/cli/v2"
)

func mountMain(v *vfs.VFS, c *cli.Context) {
	if os.Getuid() == 0 {
		disableUpdatedb()
	}
	conf := v.Conf
	conf.AttrTimeout = utils.Duration(c.String("attr-cache"))
	conf.EntryTimeout = utils.Duration(c.String("entry-cache"))
	conf.DirEntryTimeout = utils.Duration(c.String("dir-entry-cache"))
	conf.NegEntryTimeout = utils.Duration(c.String("negative-entry-cache"))
	conf.ReaddirCache = c.Bool("readdir-cache")
	major, minor := utils.GetKernelVersion()
	if conf.ReaddirCache {
		if conf.AttrTimeout == 0 {
			logger.Warnf("readdir-cache is enabled without attr-cache, it's performance may be affected")
		}
		if major < 4 || (major == 4 && minor < 20) {
			logger.Warnf("readdir-cache requires kernel version 4.20 or higher, current version: %d.%d", major, minor)
		}
		if conf.Meta.SkipDirMtime > 0 {
			logger.Warnf("When both readdir-cache and skip-dir-mtime are enabled, ignoring mtime may disable readdir refreshes on other nodes")
		}
	}
	if conf.NegEntryTimeout > 0 && (major < 5 || (major == 5 && minor < 11)) {
		logger.Warnf("On kernel versions below 5.11 (current: %d.%d), negative-entry-cache may cause concurrent check-then-create operations (e.g. mkdir -p) to fail in a distributed environment", major, minor)
	}
	conf.NonDefaultPermission = c.Bool("non-default-permission")
	rootSquash := c.String("root-squash")
	allSquash := c.String("all-squash")
	if allSquash != "" || rootSquash != "" {
		nobodyUid, nobodyGid := getNobodyUIDGID()
		// all-squash takes precedence over root-squash
		if allSquash != "" {
			conf.NonDefaultPermission = true // disable kernel permission check
			uid, gid := parseUIDGID(allSquash, nobodyUid, nobodyGid)
			conf.AllSquash = &vfs.AnonymousAccount{Uid: uid, Gid: gid}
			logger.Infof("Map all uid/gid to %d/%d by setting all-squash", uid, gid)
		} else { // rootSquash != ""
			uid, gid := parseUIDGID(rootSquash, nobodyUid, nobodyGid)
			conf.RootSquash = &vfs.AnonymousAccount{Uid: uid, Gid: gid}
			logger.Infof("Map root uid/gid 0 to %d/%d by setting root-squash", uid, gid)
		}
	}
	logger.Infof("Mounting volume %s at %s ...", conf.Format.Name, conf.Meta.MountPoint)
	err := fuse.Serve(v, c.String("o"), c.Bool("enable-xattr"), c.Bool("enable-ioctl"))
	if err != nil {
		logger.Fatalf("fuse: %s", err)
	}
}

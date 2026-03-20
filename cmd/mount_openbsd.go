//go:build openbsd

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
	"github.com/juicedata/juicefs/pkg/cgofuse"
	"github.com/juicedata/juicefs/pkg/utils"
	"github.com/juicedata/juicefs/pkg/vfs"
	"github.com/urfave/cli/v2"
)

func mountMain(v *vfs.VFS, c *cli.Context) {
	conf := v.Conf
	conf.AttrTimeout = utils.Duration(c.String("attr-cache"))
	conf.EntryTimeout = utils.Duration(c.String("entry-cache"))
	conf.DirEntryTimeout = utils.Duration(c.String("dir-entry-cache"))

	logger.Infof("Mounting volume %s at %s via cgofuse ...", conf.Format.Name, conf.Meta.MountPoint)
	err := cgofuse.Serve(v, c.String("o"))
	if err != nil {
		logger.Fatalf("fuse: %s", err)
	}
}

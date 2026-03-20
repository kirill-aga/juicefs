//go:build openbsd
// +build openbsd

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

package cgofuse

import (
	"fmt"
	"os"
	"path"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/juicedata/juicefs/pkg/fs"
	"github.com/juicedata/juicefs/pkg/meta"
	"github.com/juicedata/juicefs/pkg/utils"
	"github.com/juicedata/juicefs/pkg/vfs"
	"github.com/winfsp/cgofuse/fuse"
)

var logger = utils.GetLogger("juicefs")

type Ino = meta.Ino

type handleInfo struct {
	ino           meta.Ino
	cacheAttr     *meta.Attr
	attrExpiredAt time.Time
}

type juice struct {
	fuse.FileSystemBase
	sync.RWMutex
	conf         *vfs.Config
	vfs          *vfs.VFS
	fs           *fs.FileSystem
	host         *fuse.FileSystemHost
	handlers     map[uint64]handleInfo
	badfd        map[uint64]uint64
	inoHandleMap map[meta.Ino][]uint64

	readdirBatchSize int
	attrCacheTimeout time.Duration
}

func (j *juice) Init() {
	j.handlers = make(map[uint64]handleInfo)
	j.badfd = make(map[uint64]uint64)
	j.inoHandleMap = make(map[meta.Ino][]uint64)
}

func (j *juice) newContext() vfs.LogContext {
	uid, gid, pid := fuse.Getcontext()
	if uid == 0xffffffff {
		uid = 0
	}
	if gid == 0xffffffff {
		gid = 0
	}
	if pid == -1 {
		pid = 0
	}
	ctx := meta.NewContext(uint32(pid), uid, []uint32{gid})
	return vfs.NewLogContext(ctx)
}

func errorconv(err syscall.Errno) int {
	if err == 0 {
		return 0
	}
	return -int(err)
}

func fuseFlagToSyscall(flag int) int {
	var ret int
	if flag&fuse.O_RDONLY != 0 {
		ret |= syscall.O_RDONLY
	}
	if flag&fuse.O_WRONLY != 0 {
		ret |= syscall.O_WRONLY
	}
	if flag&fuse.O_RDWR != 0 {
		ret |= syscall.O_RDWR
	}
	if flag&fuse.O_APPEND != 0 {
		ret |= syscall.O_APPEND
	}
	if flag&fuse.O_CREAT != 0 {
		ret |= syscall.O_CREAT
	}
	if flag&fuse.O_EXCL != 0 {
		ret |= syscall.O_EXCL
	}
	if flag&fuse.O_TRUNC != 0 {
		ret |= syscall.O_TRUNC
	}
	return ret
}

func (j *juice) Statfs(p string, stat *fuse.Statfs_t) int {
	ctx := j.newContext()
	var totalspace, availspace, iused, iavail uint64
	j.fs.Meta().StatFS(ctx, meta.RootInode, &totalspace, &availspace, &iused, &iavail)
	var bsize uint64 = 4096
	blocks := totalspace / bsize
	bavail := availspace / bsize
	stat.Namemax = 255
	stat.Frsize = 4096
	stat.Bsize = bsize
	stat.Blocks = blocks
	stat.Bfree = bavail
	stat.Bavail = bavail
	stat.Files = iused + iavail
	stat.Ffree = iavail
	stat.Favail = iavail
	return 0
}

func (j *juice) Mknod(p string, mode uint32, dev uint64) (e int) {
	ctx := j.newContext()
	parent, err := j.fs.Open(ctx, path.Dir(p), 0)
	if err != 0 {
		return errorconv(err)
	}
	_, errno := j.vfs.Mknod(ctx, parent.Inode(), path.Base(p), uint16(mode), 0, uint32(dev))
	e = errorconv(errno)
	if e == 0 {
		j.fs.InvalidateEntry(parent.Inode(), path.Base(p))
	}
	return
}

func (j *juice) Mkdir(p string, mode uint32) int {
	ctx := j.newContext()
	return errorconv(j.fs.Mkdir(ctx, p, uint16(mode), 0))
}

func (j *juice) Unlink(p string) int {
	ctx := j.newContext()
	return errorconv(j.fs.Delete(ctx, p))
}

func (j *juice) Rmdir(p string) int {
	ctx := j.newContext()
	return errorconv(j.fs.Delete(ctx, p))
}

func (j *juice) Symlink(target string, newpath string) int {
	ctx := j.newContext()
	parent, err := j.fs.Open(ctx, path.Dir(newpath), 0)
	if err != 0 {
		return errorconv(err)
	}
	_, errno := j.vfs.Symlink(ctx, target, parent.Inode(), path.Base(newpath))
	return errorconv(errno)
}

func (j *juice) Readlink(p string) (int, string) {
	ctx := j.newContext()
	fi, err := j.fs.Lstat(ctx, p)
	if err != 0 {
		return errorconv(err), ""
	}
	t, errno := j.vfs.Readlink(ctx, fi.Inode())
	return errorconv(errno), string(t)
}

func (j *juice) Rename(oldpath string, newpath string) int {
	ctx := j.newContext()
	return errorconv(j.fs.Rename(ctx, oldpath, newpath, 0))
}

func (j *juice) Link(oldpath string, newpath string) int {
	ctx := j.newContext()
	fi, err := j.fs.Lstat(ctx, oldpath)
	if err != 0 {
		return errorconv(err)
	}
	parent, err := j.fs.Open(ctx, path.Dir(newpath), 0)
	if err != 0 {
		return errorconv(err)
	}
	_, errno := j.vfs.Link(ctx, fi.Inode(), parent.Inode(), path.Base(newpath))
	return errorconv(errno)
}

func (j *juice) Chmod(p string, mode uint32) int {
	ctx := j.newContext()
	f, err := j.fs.Open(ctx, p, 0)
	if err != 0 {
		return errorconv(err)
	}
	e := errorconv(f.Chmod(ctx, uint16(mode)))
	if e == 0 {
		j.invalidateAttrCache(f.Inode())
	}
	return e
}

func (j *juice) Chown(p string, uid uint32, gid uint32) int {
	ctx := j.newContext()
	f, err := j.fs.Open(ctx, p, 0)
	if err != 0 {
		return errorconv(err)
	}
	info, _ := f.Stat()
	if uid == 0xffffffff {
		uid = uint32(info.(*fs.FileStat).Uid())
	}
	if gid == 0xffffffff {
		gid = uint32(info.(*fs.FileStat).Gid())
	}
	return errorconv(f.Chown(ctx, uid, gid))
}

func (j *juice) Utimens(p string, tmsp []fuse.Timespec) int {
	ctx := j.newContext()
	f, err := j.fs.Open(ctx, p, 0)
	if err != 0 {
		return errorconv(err)
	}
	e := errorconv(f.Utime2(ctx, tmsp[0].Sec, tmsp[0].Nsec, tmsp[1].Sec, tmsp[1].Nsec))
	if e == 0 {
		j.invalidateAttrCache(f.Inode())
	}
	return e
}

func (j *juice) Create(p string, flags int, mode uint32) (int, uint64) {
	ctx := j.newContext()
	parent, err := j.fs.Open(ctx, path.Dir(p), 0)
	if err != 0 {
		return errorconv(err), 0
	}
	entry, fh, errno := j.vfs.Create(ctx, parent.Inode(), path.Base(p), uint16(mode), 0, uint32(fuseFlagToSyscall(flags)))
	if errno == 0 {
		j.Lock()
		j.handlers[fh] = handleInfo{
			ino:           entry.Inode,
			cacheAttr:     entry.Attr,
			attrExpiredAt: time.Now().Add(j.conf.AttrTimeout),
		}
		j.inoHandleMap[entry.Inode] = append(j.inoHandleMap[entry.Inode], fh)
		j.Unlock()
		j.fs.InvalidateEntry(parent.Inode(), path.Base(p))
	}
	return errorconv(errno), fh
}

func (j *juice) Open(p string, flags int) (int, uint64) {
	ctx := j.newContext()
	ino := meta.Ino(0)
	if strings.HasSuffix(p, "/.control") {
		ino, _ = vfs.GetInternalNodeByName(".control")
		if ino == 0 {
			return -fuse.ENOENT, 0
		}
	} else if filename := path.Base(p); vfs.IsSpecialName(filename) && path.Dir(p) == "/" {
		ino, _ = vfs.GetInternalNodeByName(filename)
		if ino == 0 {
			return -fuse.ENOENT, 0
		}
	} else {
		f, err := j.fs.Open(ctx, p, 0)
		if err != 0 {
			return -fuse.ENOENT, 0
		}
		ino = f.Inode()
	}
	entry, fh, errno := j.vfs.Open(ctx, ino, uint32(fuseFlagToSyscall(flags)))
	if errno == 0 {
		j.Lock()
		j.handlers[fh] = handleInfo{
			ino:           ino,
			cacheAttr:     entry.Attr,
			attrExpiredAt: time.Now().Add(j.conf.AttrTimeout),
		}
		j.inoHandleMap[ino] = append(j.inoHandleMap[ino], fh)
		j.Unlock()
	}
	return errorconv(errno), fh
}

func (j *juice) attrToStat(inode Ino, attr *meta.Attr, stat *fuse.Stat_t) {
	stat.Ino = uint64(inode)
	stat.Mode = attr.SMode()
	stat.Uid = attr.Uid
	stat.Gid = attr.Gid
	stat.Birthtim.Sec = attr.Atime
	stat.Birthtim.Nsec = int64(attr.Atimensec)
	stat.Atim.Sec = attr.Atime
	stat.Atim.Nsec = int64(attr.Atimensec)
	stat.Mtim.Sec = attr.Mtime
	stat.Mtim.Nsec = int64(attr.Mtimensec)
	stat.Ctim.Sec = attr.Ctime
	stat.Ctim.Nsec = int64(attr.Ctimensec)
	stat.Nlink = attr.Nlink
	var rdev uint32
	var size, blocks uint64
	switch attr.Typ {
	case meta.TypeDirectory, meta.TypeSymlink, meta.TypeFile:
		size = attr.Length
		blocks = (size + 0xffff) / 0x10000
		stat.Blksize = 0x10000
	case meta.TypeBlockDev, meta.TypeCharDev:
		rdev = attr.Rdev
	}
	stat.Size = int64(size)
	stat.Blocks = int64(blocks)
	stat.Rdev = uint64(rdev)
}

func (j *juice) h2i(fh *uint64) meta.Ino {
	j.RLock()
	defer j.RUnlock()
	entry := j.handlers[*fh]
	if entry.ino == 0 {
		newfh := j.badfd[*fh]
		if newfh != 0 {
			entry = j.handlers[newfh]
			if entry.ino > 0 {
				*fh = newfh
			}
		}
	}
	return entry.ino
}

func (j *juice) reopen(p string, fh *uint64) meta.Ino {
	e, newfh := j.Open(p, os.O_RDWR)
	if e != 0 {
		return 0
	}
	j.Lock()
	defer j.Unlock()
	j.badfd[*fh] = newfh
	*fh = newfh
	return j.handlers[newfh].ino
}

func (j *juice) invalidateAttrCache(ino meta.Ino) {
	j.Lock()
	defer j.Unlock()
	for _, fh := range j.inoHandleMap[ino] {
		h := j.handlers[fh]
		h.cacheAttr = nil
		j.handlers[fh] = h
	}
}

func (j *juice) getAttrFromCache(fh uint64) *meta.Entry {
	j.RLock()
	defer j.RUnlock()
	h := j.handlers[fh]
	if h.cacheAttr != nil && time.Now().Before(h.attrExpiredAt) {
		return &meta.Entry{Inode: h.ino, Attr: h.cacheAttr}
	}
	return nil
}

func (j *juice) setAttrCache(fh uint64, attr *meta.Attr) {
	j.Lock()
	defer j.Unlock()
	h := j.handlers[fh]
	h.cacheAttr = attr
	h.attrExpiredAt = time.Now().Add(j.attrCacheTimeout)
	j.handlers[fh] = h
}

func (j *juice) getAttr(ctx vfs.Context, fh uint64, ino Ino, opened uint8) (*meta.Entry, syscall.Errno) {
	if e := j.getAttrFromCache(fh); e != nil {
		return e, 0
	}
	entry, errrno := j.vfs.GetAttr(ctx, ino, opened)
	if errrno == 0 {
		j.setAttrCache(fh, entry.Attr)
	}
	return entry, errrno
}

func (j *juice) Getattr(p string, stat *fuse.Stat_t, fh uint64) int {
	ctx := j.newContext()
	ino := j.h2i(&fh)
	if ino == 0 {
		if strings.HasSuffix(p, "/.control") || (vfs.IsSpecialName(path.Base(p)) && path.Dir(p) == "/") {
			inode, attr := vfs.GetInternalNodeByName(path.Base(p))
			if inode == 0 {
				return -fuse.ENOENT
			}
			j.attrToStat(inode, attr, stat)
			return 0
		}
		fi, err := j.fs.Lstat(ctx, p)
		if err != 0 {
			return -fuse.ENOENT
		}
		ino = fi.Inode()
		entry := fi.Attr()
		if entry != nil {
			j.vfs.UpdateLength(ino, entry)
			j.attrToStat(ino, entry, stat)
			return 0
		}
	}
	entry, errrno := j.getAttr(ctx, fh, ino, 0)
	if errrno != 0 {
		return errorconv(errrno)
	}
	j.vfs.UpdateLength(entry.Inode, entry.Attr)
	j.attrToStat(entry.Inode, entry.Attr, stat)
	return 0
}

func (j *juice) Truncate(p string, size int64, fh uint64) int {
	ctx := j.newContext()
	ino := j.h2i(&fh)
	if ino == 0 {
		return -fuse.EBADF
	}
	e := errorconv(j.vfs.Truncate(ctx, ino, size, 0, nil))
	if e == 0 {
		j.invalidateAttrCache(ino)
	}
	return e
}

func (j *juice) Read(p string, buf []byte, off int64, fh uint64) int {
	ctx := j.newContext()
	ino := j.h2i(&fh)
	if ino == 0 {
		ino = j.reopen(p, &fh)
	}
	if ino == 0 {
		return -fuse.EBADF
	}
	n, err := j.vfs.Read(ctx, ino, buf, uint64(off), fh)
	if err != 0 {
		return errorconv(err)
	}
	return n
}

func (j *juice) Write(p string, buf []byte, off int64, fh uint64) int {
	ctx := j.newContext()
	ino := j.h2i(&fh)
	if ino == 0 {
		ino = j.reopen(p, &fh)
	}
	if ino == 0 {
		return -fuse.EBADF
	}
	errno := j.vfs.Write(ctx, ino, buf, uint64(off), fh)
	if errno != 0 {
		return errorconv(errno)
	}
	return len(buf)
}

func (j *juice) Flush(p string, fh uint64) int {
	ctx := j.newContext()
	ino := j.h2i(&fh)
	if ino == 0 {
		return -fuse.EBADF
	}
	return errorconv(j.vfs.Flush(ctx, ino, fh, 0))
}

func (j *juice) cleanInoHandlerMap(ino meta.Ino, fh uint64) {
	handles := j.inoHandleMap[ino]
	for i, handle := range handles {
		if handle == fh {
			j.inoHandleMap[ino] = append(handles[:i], handles[i+1:]...)
			break
		}
	}
	if len(j.inoHandleMap[ino]) == 0 {
		delete(j.inoHandleMap, ino)
	}
}

func (j *juice) Release(p string, fh uint64) int {
	ctx := j.newContext()
	orig := fh
	ino := j.h2i(&fh)
	if ino == 0 {
		return -fuse.EBADF
	}
	j.Lock()
	delete(j.handlers, fh)
	j.cleanInoHandlerMap(ino, fh)
	if orig != fh {
		delete(j.badfd, orig)
		j.cleanInoHandlerMap(ino, orig)
	}
	j.Unlock()
	j.vfs.Release(ctx, ino, fh)
	return 0
}

func (j *juice) Fsync(p string, datasync bool, fh uint64) int {
	ctx := j.newContext()
	ino := j.h2i(&fh)
	if ino == 0 {
		return -fuse.EBADF
	}
	return errorconv(j.vfs.Fsync(ctx, ino, 1, fh))
}

func (j *juice) Opendir(p string) (int, uint64) {
	ctx := j.newContext()
	f, err := j.fs.Open(ctx, p, 0)
	if err != 0 {
		return -fuse.ENOENT, 0
	}
	fh, errno := j.vfs.Opendir(ctx, f.Inode(), 0)
	if errno == 0 {
		j.Lock()
		j.handlers[fh] = handleInfo{ino: f.Inode()}
		j.inoHandleMap[f.Inode()] = append(j.inoHandleMap[f.Inode()], fh)
		j.Unlock()
	}
	return errorconv(errno), fh
}

func (j *juice) Readdir(p string,
	fill func(name string, stat *fuse.Stat_t, ofst int64) bool,
	ofst int64, fh uint64) int {
	ctx := j.newContext()
	ino := j.h2i(&fh)
	if ino == 0 {
		return -fuse.EBADF
	}
	currentOffset := int(ofst)
	for {
		entries, readAt, err := j.vfs.Readdir(ctx, ino, uint32(j.readdirBatchSize), currentOffset, fh, true)
		if err != 0 {
			return errorconv(err)
		}
		if len(entries) == 0 {
			break
		}
		var st fuse.Stat_t
		full := true
		for _, e := range entries {
			if !e.Attr.Full {
				full = false
				break
			}
		}
		for _, e := range entries {
			name := string(e.Name)
			if full {
				if j.vfs.ModifiedSince(e.Inode, readAt) {
					if e2, err := j.vfs.GetAttr(ctx, e.Inode, 0); err == 0 {
						e.Attr = e2.Attr
					}
				}
				j.vfs.UpdateLength(e.Inode, e.Attr)
				j.attrToStat(e.Inode, e.Attr, &st)
				if !fill(name, &st, 0) {
					break
				}
			} else {
				if !fill(name, nil, 0) {
					break
				}
			}
		}
		currentOffset += len(entries)
	}
	return 0
}

func (j *juice) Releasedir(p string, fh uint64) int {
	ctx := j.newContext()
	ino := j.h2i(&fh)
	if ino == 0 {
		return -fuse.EBADF
	}
	j.Lock()
	delete(j.handlers, fh)
	j.cleanInoHandlerMap(ino, fh)
	j.Unlock()
	return -int(j.vfs.Releasedir(ctx, ino, fh))
}

// Serve mounts the JuiceFS volume using cgofuse (OpenBSD-compatible FUSE via libfuse).
func Serve(v *vfs.VFS, options string) error {
	conf := v.Conf
	var jfs juice
	jfs.conf = conf
	jfs.vfs = v
	jfs.readdirBatchSize = 1000
	jfs.attrCacheTimeout = conf.AttrTimeout

	var err error
	jfs.fs, err = fs.NewFileSystem(conf, v.Meta, v.Store, nil)
	if err != nil {
		return fmt.Errorf("initialize FileSystem: %v", err)
	}

	host := fuse.NewFileSystemHost(&jfs)
	jfs.host = host
	host.SetCapReaddirPlus(true)

	var args []string
	args = append(args, "") // argv[0] placeholder
	args = append(args, conf.Meta.MountPoint)
	if os.Getuid() == 0 {
		args = append(args, "-o", "allow_other")
	}
	if options != "" {
		args = append(args, "-o", options)
	}

	logger.Infof("Mounting volume %s at %s via cgofuse ...", conf.Format.Name, conf.Meta.MountPoint)
	ok := host.Mount(conf.Meta.MountPoint, args)
	if !ok {
		return fmt.Errorf("cgofuse mount failed")
	}
	return nil
}

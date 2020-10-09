#!/usr/bin/zsh -f

dev=/dev/loop0
rtdev=/dev/loop1
mntpnt=/mnt/
fssize=1G
bsize=4096
fillfs=${mntpnt}/fill-fs.bin
# dirbsize=65536
dirbsize=4096

mkfs_and_mount()
{
	umount $dev > /dev/null 2>&1
	mkfs.xfs -f -K -n size=${dirbsize} -b size=${bsize} -d size=${fssize} -m reflink=1,rmapbt=1 $dev || \
		{ print "Unable to mkfs.xfs $dev"; exit 1 }
	mount -o uquota $dev $mntpnt || \
		{ print "Unable to mount $dev"; exit 1 }
}

# convert delalloc
add_nosplit_0_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	nr_blks=$((15 * 2))

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 0 2 $(($nr_blks - 1))); do
		xfs_io -f -c "pwrite $(($i * $bsize)) $bsize" -c fsync $testfile > /dev/null 2>&1
		[[ $? != 0 ]] && { echo "Failed to write at block $i"; break; }
	done

	ls -i $testfile
	xfs_io -f -c "fiemap" $testfile | grep -i -v hole
}

# falloc
add_nosplit_1_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	nr_blks=$((15 * 2))

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 0 2 $(($nr_blks - 1))); do
		xfs_io -f -c "falloc $(($i * $bsize)) $bsize" $testfile > /dev/null 2>&1
		[[ $? != 0 ]] && { echo "Failed to write at block $i"; break; }
	done

	ls -i $testfile
	xfs_io -f -c "fiemap" $testfile | grep -i -v hole
}

# quota inode
add_nosplit_2_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	touch ${testfile}
	dd if=/dev/zero of=${testfile} bs=4k
	sync
	/root/repos/xfstests-dev/src/punch-alternating $testfile
	sync

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt
	xfs_io -x -c 'inject bmap_alloc_minlen_extent' $mntpnt

	nr_blks=15

	# gdb -batch /root/junk/build/linux//vmlinux -ex 'print sizeof(struct xfs_disk_dquot)'
	# $1 = 104
	# This is a rough calculation; It doesn't take block headers into consideration.
	nr_quotas_per_block=$(($bsize / 104))
	nr_quotas=$(($nr_quotas_per_block * $nr_blks))

	for i in $(seq 0 $nr_quotas); do
		chown $i $testfile
		
		if [[ $? != 0 ]]; then
			umount ${mntpnt}
			uquotino=$(xfs_db -c sb -c 'print uquotino' $dev)
			uquotino=${uquotino##uquotino = }
			xfs_db -c "inode $uquotino" -c "print core.nextents" -c "print u3.bmx" $dev
			mount $dev $mntpnt
			return
		fi
	done

	umount ${mntpnt}
	uquotino=$(xfs_db -c sb -c 'print uquotino' $dev)
	uquotino=${uquotino##uquotino = }
	xfs_db -c "inode $uquotino" -c "print core.nextents" -c "print u3.bmx" $dev
	mount $dev $mntpnt

}

# direct i/o
add_nosplit_3_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	nr_blks=$((15 * 2))

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 0 2 $(($nr_blks - 1))); do
		xfs_io -d -f -c "pwrite $(($i * $bsize)) $bsize" -c fsync $testfile > /dev/null 2>&1
		[[ $? != 0 ]] && { echo "Failed to write at block $i"; break; }
	done

	ls -i $testfile
	xfs_io -f -c "fiemap" $testfile | grep -i -v hole
}

# rtalloc
add_nosplit_4_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	umount $dev

	mkfs.xfs -f -K -d size=${fssize} -r rtdev=${rtdev},size=10M -m reflink=0,rmapbt=0 $dev || \
		{ print "Unable to mkfs.xfs $dev"; exit 1 }

 	mount -o rtdev=${rtdev} $dev $mntpnt || { print "Unable to mount $dev"; exit 1 }

	dd if=/dev/zero of=${testfile} bs=4k
	sync

	/root/repos/xfstests-dev/src/punch-alternating $testfile
	sync

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt
	xfs_io -x -c 'inject bmap_alloc_minlen_extent' $mntpnt

	xfs_growfs $mntpnt || { print "Unable to grow xfs;"}
}

# realtime file
add_nosplit_5_iext_count_overflow_check()
{
	umount $dev

	mkfs.xfs -f -K -d size=${fssize} -r rtdev=${rtdev} -m reflink=0,rmapbt=0 $dev || \
		{ print "Unable to mkfs.xfs $dev"; exit 1 }

	mount -o rtdev=${rtdev} $dev $mntpnt || { print "Unable to mount $dev"; exit 1 }

	testfile=${mntpnt}/testfile
	nr_blks=$((15 * 2))

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 0 2 $(($nr_blks - 1))); do
		xfs_io -Rf -c "pwrite $(($i * $bsize)) $bsize" -c fsync $testfile > /dev/null 2>&1
		[[ $? != 0 ]] && { echo "Failed to write at block $i"; break; }
	done

	ls -i $testfile
	# Make sure that this is a realtime file
	xfs_io -c 'lsattr' $testfile
	xfs_io -f -c "fiemap" $testfile | grep -i -v hole
}

# Punch hole - xfs_free_file_space() => xfs_unmap_extent()
punch_hole_0_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	nr_blks=30

	xfs_io -f -c "pwrite -b $(($nr_blks * $bsize)) 0 $(($nr_blks * $bsize))" -c sync -c fiemap $testfile
	
	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	/root/repos/xfstests-dev/src/punch-alternating $testfile
	if [[ $? == 0 ]]; then
		print "Punch alternate succeeded"
	else
		print "Punch alternate did not succeed"
	fi

	xfs_io -c fiemap $testfile | grep -i -v hole 
}

# xfs_insert_file_space
punch_hole_1_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	nr_blks=30

	xfs_io -f -c "pwrite -b $(($nr_blks * $bsize)) 0 $(($nr_blks * $bsize))" -c sync -c fiemap $testfile
	
	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 1 2 $((nr_blks - 1))); do
		xfs_io -f -c "finsert $(($i * $bsize)) $bsize" $testfile
		[[ $? != 0 ]] && { print "finsert failed at seq $i"; break; }
	done

	xfs_io -c fiemap $testfile | grep -i -v hole
}

# xfs_collapse_file_space
punch_hole_2_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	nr_blks=30

	xfs_io -f -c "pwrite -b $(($nr_blks * $bsize)) 0 $(($nr_blks * $bsize))" -c sync -c fiemap $testfile
	
	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 1 $((nr_blks / 2 - 1))); do
		xfs_io -f -c "fcollapse $(($i * $bsize)) $bsize" $testfile
		[[ $? != 0 ]] && { print "fcollapse failed at seq $i"; break; }
	done

	xfs_io -c fiemap $testfile | grep -i -v hole
}

# fzero
punch_hole_3_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	nr_blks=30

	xfs_io -f -c "pwrite -b $(($nr_blks * $bsize)) 0 $(($nr_blks * $bsize))" -c sync -c fiemap $testfile
	
	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 1 2 $((nr_blks - 1))); do
		echo "seq = $i"
		xfs_io -f -c "fzero $(($i * $bsize)) $bsize" $testfile
		[[ $? != 0 ]] && { print "fzero failed at seq $i"; break; }
	done

	xfs_io -c fiemap $testfile | grep -i -v hole
}

attr_iext_count_overflow_check()
{
	attr_len=$(uuidgen | wc -c)
	blksz=$(stat -f -c %S ${mntpnt})
	nr_attrs=$(($blksz * 20 / $attr_len))
	testfile=${mntpnt}/testfile

	touch $testfile
	dd if=/dev/zero of=${testfile} bs=4k
	sync
	/root/repos/xfstests-dev/src/punch-alternating $testfile
	sync

	print "nr_attrs = $nr_attrs; attr_len = $attr_len"

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt
	xfs_io -x -c 'inject bmap_alloc_minlen_extent' $mntpnt
	
	for i in $(seq 1 $nr_attrs); do
		setfattr -n "trusted.""$(uuidgen)" $testfile || break;
	done

	ls -i $testfile
	xfs_io -f -c "fiemap -a" $testfile
}

# Directory: Create new files
dir_entry_create_0_iext_count_overflow_check()
{
	dent_len=$(uuidgen | wc -c)
	blksz=$(stat -f -c %S ${mntpnt})
	nr_dents=$(($dirbsize * 20 / $dent_len))
	testfile=${mntpnt}/testfile

	touch $testfile
	dd if=/dev/zero of=${testfile} bs=4k
	sync
	/root/repos/xfstests-dev/src/punch-alternating $testfile
	# /root/repos/xfstests-dev/src/punch-alternating -o 16 -s 16 -i 32 /mnt/testfile
	sync

	print "nr_dents = $nr_dents; dent_len = $dent_len"

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt
	xfs_io -x -c 'inject bmap_alloc_minlen_extent' $mntpnt

	# xfs_io -x -c 'fsmap' $mntpnt

	for i in $(seq 1 $nr_dents); do
		touch ${mntpnt}/$(uuidgen) || break
	done

	xfs_bmap ${mntpnt}
}

# link
dir_entry_create_1_iext_count_overflow_check()
{
	dent_len=$(uuidgen | wc -c)
	blksz=$(stat -f -c %S ${mntpnt})
	nr_dents=$(($dirbsize * 20 / $dent_len))
	testfile=${mntpnt}/testfile

	touch $testfile
	dd if=/dev/zero of=${testfile} bs=4k
	sync
	/root/repos/xfstests-dev/src/punch-alternating $testfile
	sync

	print "nr_dents = $nr_dents; dent_len = $dent_len"

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt
	xfs_io -x -c 'inject bmap_alloc_minlen_extent' $mntpnt

	# xfs_io -x -c 'fsmap' $mntpnt

	for i in $(seq 1 $nr_dents); do
		link $testfile ${mntpnt}/$(uuidgen) || break;
	done

	xfs_bmap ${mntpnt}
}

# directory: rename
dir_entry_create_2_iext_count_overflow_check()
{
	dent_len=$(uuidgen | wc -c)
	blksz=$(stat -f -c %S ${mntpnt})
	nr_dents=$(($dirbsize * 20 / $dent_len))
	testfile=${mntpnt}/testfile
	dstdir=${mntpnt}/dstdir

	touch $testfile
	mkdir $dstdir
	dd if=/dev/zero of=${testfile} bs=4k
	sync
	/root/repos/xfstests-dev/src/punch-alternating $testfile
	sync

	print "nr_dents = $nr_dents; dent_len = $dent_len"

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt
	xfs_io -x -c 'inject bmap_alloc_minlen_extent' $mntpnt

	# xfs_io -x -c 'fsmap' $mntpnt

	for i in $(seq 1 $nr_dents); do
		tmpfile=${mntpnt}/$(uuidgen)
		touch $tmpfile || break;
		mv $tmpfile $dstdir || break;
	done

	xfs_bmap ${mntpnt}
}

# directory: symlink
dir_entry_create_3_iext_count_overflow_check()
{
	dent_len=$(uuidgen | wc -c)
	blksz=$(stat -f -c %S ${mntpnt})
	nr_dents=$(($dirbsize * 20 / $dent_len))
	testfile=${mntpnt}/testfile

	touch $testfile
	dd if=/dev/zero of=${testfile} bs=4k
	sync
	/root/repos/xfstests-dev/src/punch-alternating $testfile
	sync

	print "nr_dents = $nr_dents; dent_len = $dent_len"

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt
	xfs_io -x -c 'inject bmap_alloc_minlen_extent' $mntpnt

	# xfs_io -x -c 'fsmap' $mntpnt

	for i in $(seq 1 $nr_dents); do
		ln -s $testfile ${mntpnt}/$(uuidgen) || break;
	done

	xfs_bmap ${mntpnt}
}

dir_entry_create_4_iext_count_overflow_check()
{
	dent_len=$(uuidgen | wc -c)
	blksz=$(stat -f -c %S ${mntpnt})
	nr_dents=$(($dirbsize * 3 / $dent_len))
	testfile=${mntpnt}/testfile
	srcdir=${mntpnt}/srcdir
	dstdir=${mntpnt}/dstdir

	mkdir $srcdir $dstdir

	dd if=/dev/zero of=${testfile} bs=4k
	sync
	/root/repos/xfstests-dev/src/punch-alternating $testfile
	sync

	xfs_io -x -c 'inject bmap_alloc_minlen_extent' $mntpnt

	for i in $(seq 1 $nr_dents); do
		touch ${srcdir}/$(uuidgen) || break
	done

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for dentry in $(ls -1 $srcdir); do
		mv ${srcdir}/${dentry} $dstdir || break
	done

}

dir_entry_remove_4_iext_count_overflow_check()
{
	dent_len=$(uuidgen | wc -c)
	blksz=$(stat -f -c %S ${mntpnt})
	nr_dents=$(($dirbsize * 3 / $dent_len))
	testfile=${mntpnt}/testfile

	touch $testfile
	dd if=/dev/zero of=${testfile} bs=4k
	sync
	/root/repos/xfstests-dev/src/punch-alternating $testfile
	sync

	print "nr_dents = $nr_dents; dent_len = $dent_len"

	xfs_io -x -c 'inject bmap_alloc_minlen_extent' $mntpnt

	last=""
	for i in $(seq 1 $nr_dents); do
		last=$(uuidgen)
		touch ${mntpnt}/$last
	done

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	rm  ${mntpnt}/$last

	xfs_bmap ${mntpnt}
}


# buffer i/o - processed by bio's endio
write_unwritten_0_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	# nr_exts = summation(1, x/2, 2)
	# nr_exts = 2 * (x / 2)
	# nr_exts = x
	# x = 15
	
	nr_blks=15

	xfs_io -f -c "falloc  0 $(($nr_blks * $bsize))" -c sync -c fiemap $testfile

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 1 2 $(($nr_blks - 1))); do
		xfs_io -f -c "pwrite $(($i * $bsize)) $bsize" -c fsync $testfile > /dev/null 2>&1
		[[ $? != 0 ]] && { echo "Failed to write at block $i"; break; }
	done

	xfs_io -c fiemap $testfile | grep -i -v hole
	ls -i $testfile
}

# direct i/o
write_unwritten_1_iext_count_overflow_check()
{
	testfile=${mntpnt}/testfile

	# nr_exts = summation(1, x/2, 2)
	# nr_exts = 2 * (x / 2)
	# nr_exts = x
	# x = 15
	
	nr_blks=15

	xfs_io -f -c "falloc  0 $(($nr_blks * $bsize))" -c sync -c fiemap $testfile

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 1 2 $(($nr_blks - 1))); do
		xfs_io -f -d -c "pwrite $(($i * $bsize)) $bsize" $testfile > /dev/null 2>&1
		[[ $? != 0 ]] && { echo "Failed to write at block $i"; break; }
	done

	xfs_io -c fiemap $testfile | grep -i -v hole
	ls -i $testfile
}

reflink_end_cow_iext_count_overflow_check()
{
	src=${mntpnt}/srcfile
	dst=${mntpnt}/dstfile

	# nr_exts = summation(1, x/2, 2)
	# nr_exts = 2 * (x / 2)
	# nr_exts = x
	# x = 15
	
	nr_blks=15

	xfs_io -f -c "pwrite -b $(($nr_blks * $bsize))  0 $(($nr_blks * $bsize))" -c sync -c fiemap $src

	xfs_io -f -c "reflink $src" -c sync -c fiemap $dst

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt
	for i in $(seq 1 2 $(($nr_blks - 1))); do
		xfs_io -f -c "pwrite $(($i * $bsize)) $bsize" -c fsync $dst > /dev/null 2>&1
		[[ $? != 0 ]] && { echo "Failed to write at block $i"; break; }
	done

	xfs_io -c fiemap $dst | grep -i -v hole 
	ls -i $dst
}

reflink_remap_iext_count_overflow_check()
{
	src=${mntpnt}/srcfile
	dst=${mntpnt}/dstfile

	# nr_exts = summation(1, x/2, 2)
	# nr_exts = 2 * (x / 2)
	# nr_exts = x
	# x = 15
	
	nr_blks=15

	xfs_io -f -c "pwrite -b $(($nr_blks * $bsize))  0 $(($nr_blks * $bsize))" -c sync -c fiemap $src > /dev/null 2>&1
	xfs_io -f -c "pwrite -b $(($nr_blks * $bsize))  0 $(($nr_blks * $bsize))" -c sync -c fiemap $dst > /dev/null 2>&1

	xfs_io -c fiemap $src | grep -i -v hole
	xfs_io -c fiemap $dst | grep -i -v hole

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	for i in $(seq 1 2 $(($nr_blks - 1))); do
		xfs_io -f -c "reflink $src $(($i * $bsize)) $(($i * $bsize)) $bsize" $dst > /dev/null 2>&1
		[[ $? != 0 ]] && { echo "Failed to write at block $i"; break; }
	done

	xfs_io -c fiemap $dst | grep -i -v hole 
	ls -i $dst
}

swap_rmap_iext_count_overflow_check()
{
	donor=${mntpnt}/donorfile
	src=${mntpnt}/srcfile

	xfs_io -f -c "pwrite -b $((17 * $bsize)) 0 $((17 * $bsize))" -c sync $donor
	for i in $(seq 5 10); do
		start_offset=$(($i * $bsize))
		xfs_io -f -c "fcollapse $start_offset $bsize" $donor
	done

	xfs_io -f -c "pwrite -b $((18 * $bsize)) 0 $((18 * $bsize))" -c sync $src
	for i in $(seq 1 7); do
		start_offset=$(($i * $bsize))
		xfs_io -f -c "fcollapse $start_offset $bsize" $src
	done

	filefrag -b4096 -v $donor
	filefrag -b4096 -v $src

	xfs_io -x -c 'inject reduce_max_iextents' $mntpnt

	xfs_io -f -c "swapext $donor" $src
}

tests=(add_nosplit_0_iext_count_overflow_check
       add_nosplit_1_iext_count_overflow_check
       add_nosplit_2_iext_count_overflow_check
       add_nosplit_3_iext_count_overflow_check
       add_nosplit_4_iext_count_overflow_check
       add_nosplit_5_iext_count_overflow_check
       punch_hole_0_iext_count_overflow_check
       punch_hole_1_iext_count_overflow_check
       punch_hole_2_iext_count_overflow_check
       punch_hole_3_iext_count_overflow_check
       attr_iext_count_overflow_check
       dir_entry_create_0_iext_count_overflow_check
       dir_entry_create_1_iext_count_overflow_check
       dir_entry_create_2_iext_count_overflow_check
       dir_entry_create_3_iext_count_overflow_check
       dir_entry_create_4_iext_count_overflow_check
       dir_entry_remove_4_iext_count_overflow_check
       write_unwritten_0_iext_count_overflow_check
       write_unwritten_1_iext_count_overflow_check
       reflink_end_cow_iext_count_overflow_check
       reflink_remap_iext_count_overflow_check
       swap_rmap_iext_count_overflow_check
)

for t in ${tests}; do
	echo "Executing ... $t"
	mkfs_and_mount || { exit 1; }
	$t
	# umount $mntpnt
	echo "\n\n"
done

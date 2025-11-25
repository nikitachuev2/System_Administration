alltasks: task1 task2 task3 task4 task6 task7 task8 task5

task1: prep
	strace -tt -T -y -e trace=file -o logs/01.strace ./tasks/01-permissions/broken.sh || true

task2: prep
	strace -tt -T -y -s 120 -e trace=file -o logs/02.strace ./tasks/02-missing-file/broken.sh || true

task3: prep
	strace -f -tt -T -yy -s 200 -o logs/03.strace -e trace=network,recvfrom,sendto,connect,getsockopt,select,poll,epoll_pwait python3 tasks/03-dns-timeout/client.py || true

task4: prep
	strace -tt -T -yy -e trace=network -o logs/04.strace ./tasks/04-port-denied/tcp.sh || true

task5: prep
	strace -f -tt -T -s 200 -y -o logs/05.strace python3 tasks/05-file-lock/lock.py &
	sleep 2
	pkill -f "lock.py"
	wait $$PY_PID 2>/dev/null || true

task6: prep
	strace -tt -T -e trace=write,fsync,futex -o logs/06.strace python3 tasks/06-slow-fsync/slow_write.py || true

task7: prep
	strace -ff -tt -T -y -s 120 -o logs/07 bash tasks/07-daemonize/daemon.sh || true

task8: prep
	AA_CACHE=$$(mktemp -d); \
	cp tasks/08-apparmor/profile $$AA_CACHE/profile; \
	sudo /sbin/apparmor_parser -r -T $$AA_CACHE/profile || echo "AppArmor недоступен — будет EACCES от прав файла"; \
	strace -tt -T -y -e trace=file -o logs/08.strace python3 -c "open('/etc/shadow').read()" || true; \
	sudo aa-remove-unknown 2>/dev/null || true; \
	rm -rf $$AA_CACHE

prep:
	mkdir -p logs
	chmod +x tasks/*/*.sh tasks/*/*.py 2>/dev/null || true

clean:
	rm -f logs/*.strace

.PHONY: all alltasks prep task1 task2 task3 task4 task5 task6 task7 task8 clean

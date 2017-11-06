CC=gcc
FLAGS=-Wall -Wextra -pthread 

DAEMON=udplogd

all: $(DAEMON)

$(DAEMON): $(DAEMON).c $(DAEMON).h
	$(CC) $(FLAGS) $(DAEMON).c -o $(DAEMON)

clean:
	rm -f *.o a.out $(DAEMON)

test: test.sh $(DAEMON)
	./test.sh $(DAEMON)

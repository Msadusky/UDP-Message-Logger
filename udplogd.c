/******************************************************
 * udplogd - Simple udp message logger
 *
 * This program creates a daemon listening
 * for udp messages and writting them to
 * disk as they come in.
 *
 * Author: Michael Sadusky <msadusky@kent.edu>
 * Version: 1.0
 *****************************************************/

#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <string.h>
#include <signal.h>
#include "udplogd.h"

/*****************/
/*    GLOBAL     */
/*****************/

int end = 0;
int sockfd = 0;
pthread_mutex_t lock;
FILE * log_file;
pthread_t threads[MAX_THREADS];
int threadStatus = 0;

/*****************/
/*  END GLOBAL   */
/*****************/

/*****************/
/*   FUNCTIONS   */
/*****************/

/* Packet logging function */
void *logPacket(void *arg)
{
	int msg = 0;
	char buff[MAX_MSG_BUFF] = {0};

	while(1)
	{
		/* Waiting for input */
		if((msg = recvfrom(sockfd, buff, MAX_MSG_BUFF, 0, NULL, NULL)) != 0)
		{

			pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);

			pthread_mutex_lock(&lock);

			fwrite(buff, 1, msg, stdout);

			pthread_mutex_unlock(&lock);

			pthread_testcancel();

			pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL);

			msg = 0;
		}
	}
}

void gracefulExit(int sig)
{
	/* Close listening port */
	close(sockfd);

	/* Thread management */
	int i = 0;
	for(i = 0; i < MAX_THREADS; i++)
	{
		pthread_cancel(threads[i]);
	}

	i = 0;
	for(i = 0; i < MAX_THREADS; i++)
	{
		pthread_join(threads[i], NULL);
	}

	/* Flush any remnants of data in the stream */
	fflush(NULL);

	fclose(log_file);

	end = 1;
}

/*****************/
/* END FUNCTIONS */
/*****************/

int main()
{
	pid_t procid, sid;

	struct sockaddr_in my_addr;

	int ret = 0;
	int i = 0;

	struct stat st;

	struct sigaction usersig;
	sigset_t process_mask;
	sigset_t handler_mask;
	sigfillset(&handler_mask);
	memset(&usersig, 0, sizeof(struct sigaction));
	usersig.sa_handler = gracefulExit;
	usersig.sa_mask = handler_mask;
	sigaction(SIGTERM, &usersig, NULL);
	sigfillset(&process_mask);
	sigdelset(&process_mask, SIGTERM);
	sigprocmask(SIG_SETMASK, &process_mask, NULL);

    memset( &my_addr, 0, sizeof(struct sockaddr_in) );
    my_addr.sin_family = AF_INET;
    my_addr.sin_addr.s_addr = INADDR_ANY;
    my_addr.sin_port = htons(UDP_LOGGER_PORT);

	sockfd = socket(AF_INET,SOCK_DGRAM, 0);

	ret = bind(sockfd, (const struct sockaddr *) &my_addr, sizeof(my_addr));

	if(ret != 0)
	{
		perror("Bind failed!");
		exit(EXIT_FAILURE);
	}

	/* Check to see if log already exists */
	if(stat("udplogd.pid", &st) == 0)
	{
		perror("PID File Found");
		exit(EXIT_FAILURE);
	}

	umask(0022);

  procid = fork();

  if(procid < 0)
	{
        perror("Fork Failed!");
        exit(EXIT_FAILURE);
	}
	else if(procid > 0)
	{
		exit(EXIT_SUCCESS);
	}

    sid = setsid();

    if(sid < 0)
	{
        perror("Setsid failed");
        exit(EXIT_FAILURE);
    }

	log_file = fopen("udplogd.log", "a");
	freopen("udplogd.log", "a", stderr);
	freopen("udplogd.log", "a", stdout);

    /* Get our pid and write it to a file */
    procid = getpid();

	/* Initializing stream */
	FILE * file;

	/* Creating our pid file */
	file = fopen("udplogd.pid", "w");

	/* Write to file */
	fprintf(file, "%d", procid);

	/* Closing stream */
	fclose (file);

	/* Initializing the mutex */
	pthread_mutex_init(&lock, NULL);

	/* Make threads do work */
	for(i = 0; i < MAX_THREADS; i++)
	{
		threadStatus = pthread_create(&threads[i], NULL, logPacket, NULL);
		if(threadStatus != 0)
		{
			perror("Failed to create threads");
			exit(EXIT_FAILURE);
		}
	}

	/* Keeps code running to keep polling */
	while(1)
	{
		if(end == 1)
		{
			break;
		}
		sleep(1);
	}

	/* This to do after process is ended */
	return EXIT_SUCCESS;
}

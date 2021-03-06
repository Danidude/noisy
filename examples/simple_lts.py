#!/usr/bin/python

"""
A simple (and slow) case of a LTS (local thompson sampling) with a normal distribution.
"""



import math
import random


class LTS:
    def __init__(self,N, init_mu, init_sd, observation_noise):
        """
        init_variance and observation_variance are in there standard deviation form.
        so the variance is the square of them.
        """
        self._arms = [(init_mu, init_sd) for _ in range(0, N)]
        self._observation_noise = observation_noise
        self._last_arm_pulled = None
        
    def select(self):
        """
        returns a arm index in [0, N-1] 
        """
        self._last_arm_pulled = max( enumerate(self._arms), key=lambda x:random.gauss(*x[1]))[0] 
        return self._last_arm_pulled
    
    def update(self, reward):
        """
        Takes the reward and updates the last arm pulled based on the conjugate prior. 
        """
        arm          = self._arms[self._last_arm_pulled]

        arm_mean     = arm[0]        
        arm_variance = arm[1] * arm[1]
        ob_variance  = self._observation_noise * self._observation_noise
        
        
        mu = (arm_variance)*reward + (ob_variance)*arm_mean
        mu /= (arm_variance + ob_variance)
        
        
        var = arm_variance * ob_variance
        var /= (arm_variance + ob_variance)
        sd  = math.sqrt(var)
        
        self._arms[self._last_arm_pulled] = (mu, sd)
    
        
"""
Simple simulation
"""
# environment setup
arm1 = (5.0, 2.0)   # ~N(5.0,2.0;x)  the best arm
arm2 = (1.0, 1.0)   # ~N(2.0,2.0;x)  the worst arm
arm3 = (2.0, 2.0) 
arms = [arm1, arm2, arm3]
filename = "testdata.txt"
datalist = []
FILE = open(filename, "w")
saveNumber = 0
T = 1000
cumulative_reward = 0.0
highestObsScore = 0
highestObs = 0



# bandits setup
init_mean_for_bandits = 3.5
init_sd_for_bandits = 3.0
observation_noise = 0.1
ob_n = 10



print( "Starting simulation." )
for noise in range(ob_n):
    cumulative_reward = 0.0
    bandit = LTS( len(arms), init_mean_for_bandits, init_sd_for_bandits, observation_noise)
    
    for t in range(T):
        selected_arm = bandit.select()
        saveNumber = saveNumber + 1
        if (saveNumber > 500):
            FILE.writelines(datalist)
            del datalist[:]
            saveNumber = 0
        
        # response from env
        reward = random.gauss( *arms[selected_arm] )
        cumulative_reward += reward
        
        # give it back to the bandit
        bandit.update(reward)
        
    if highestObsScore < cumulative_reward:
        highestObsScore = cumulative_reward
        highestObs = observation_noise
    datalist.append("Cumulative reward: {:.2f} after {} rounds using ob: {}".format(cumulative_reward, T, observation_noise)+"\n\n")    
    observation_noise = observation_noise + 0.1

print( "Done with the simulation." )
print( "Obervasion noise: {} with ighest score: {}".format(highestObs, highestObsScore) )
datalist.append("Done with the simulation.\n")
FILE.writelines(datalist)
del datalist[:]
FILE.close()
    
    


        
         

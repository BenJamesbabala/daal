/* file: naivebayes_train_impl.i */
/*******************************************************************************
* Copyright 2014-2016 Intel Corporation
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
*******************************************************************************/

/*
//++
//  Implementation of Naive Bayes algorithm.
//
//  Based on paper: Tackling the Poor Assumptions of Naive Bayes Text Classifiers
//  Url: http://people.csail.mit.edu/jrennie/papers/icml03-nb.pdf
//--
*/

#ifndef __NAIVEBAYES_TRAIN_FAST_I__
#define __NAIVEBAYES_TRAIN_FAST_I__

#include "algorithm.h"
#include "numeric_table.h"
#include "threading.h"
#include "daal_defines.h"

#include "service_math.h"
#include "service_memory.h"
#include "service_micro_table.h"
#include "csr_numeric_table.h"

#include "service_data_utils.h"


#if( __CPUID__(DAAL_CPU) == __avx512_mic__ )

    #define _CALLOC_      service_scalable_calloc
    #define _FREE_        service_scalable_free

#else

    #define _CALLOC_      service_calloc
    #define _FREE_        service_free

#endif


using namespace daal::internal;
using namespace daal::services::internal;

namespace daal
{
namespace algorithms
{
namespace multinomial_naive_bayes
{
namespace training
{
namespace internal
{

template<typename algorithmFPType, Method method, CpuType cpu>
struct localDataCollector {};

template<typename algorithmFPType, CpuType cpu>
struct localDataCollector<algorithmFPType, defaultDense, cpu>
{
    size_t _p;
    size_t _c;

    BlockDescriptor<algorithmFPType> blData;
    BlockDescriptor<int> blClass;

    NumericTable *ntData;
    NumericTable *ntClass;

    algorithmFPType *n_ci;

    localDataCollector(size_t p, size_t c,
                       NumericTable *_ntData, NumericTable *_ntClass, algorithmFPType *local_n_ci) :
        _p(p), _c(c), ntData(_ntData), ntClass(_ntClass),
        n_ci(local_n_ci)
    {}

    size_t getBlockSize(size_t n)
    {
        return 256;
    }

    void addData(size_t nStart, size_t blockSize)
    {
        ntData ->getBlockOfRows(nStart, blockSize, readOnly, blData);
        ntClass->getBlockOfRows(nStart, blockSize, readOnly, blClass);
        algorithmFPType *data        = blData .getBlockPtr();
        int *predefClass = blClass.getBlockPtr();

        for( size_t j=0; j<blockSize; j++ )
        {
            int  cl   = predefClass[j];

          PRAGMA_SIMD_ASSERT
            for( size_t i=0 ; i<_p; i++ )
            {
                n_ci[ cl*_p + i ] += data[j*_p + i];
            }
        }

        ntClass->releaseBlockOfRows(blClass);
        ntData ->releaseBlockOfRows(blData );
    }
};

template<typename algorithmFPType, CpuType cpu>
struct localDataCollector<algorithmFPType, fastCSR, cpu>
{
    size_t _p;
    size_t _c;

    CSRBlockDescriptor<algorithmFPType> dataBlock;
    BlockDescriptor<int>    classesBlock;

    CSRNumericTableIface *ntData;
    NumericTable *ntClass;

    algorithmFPType *n_ci;

    localDataCollector(size_t p, size_t c,
        NumericTable *_ntData, NumericTable *_ntClass, algorithmFPType *local_n_ci) :
        _p(p), _c(c), ntData(dynamic_cast<CSRNumericTableIface *>(_ntData)), ntClass(_ntClass),
        n_ci(local_n_ci)
    {}

    size_t getBlockSize(size_t n)
    {
        return n;
    }

    void addData(size_t nStart, size_t blockSize)
    {
        ntData->getSparseBlock( nStart, blockSize, readOnly, dataBlock );
        ntClass->getBlockOfRows( nStart, blockSize, readOnly, classesBlock );

        algorithmFPType    *data        = dataBlock.getBlockValuesPtr();
        size_t *colIdx      = dataBlock.getBlockColumnIndicesPtr();
        size_t *rowIdx      = dataBlock.getBlockRowIndicesPtr();
        int    *predefClass = classesBlock.getBlockPtr();

        size_t k = 0;

        for( size_t j=0; j<blockSize; j++ )
        {
            size_t cl = predefClass[j];
            size_t jn = rowIdx[j+1] - rowIdx[j];

          PRAGMA_SIMD_ASSERT
            for( size_t i=0 ; i<jn; i++ )
            {
                size_t col = colIdx[k+i]-1;

                n_ci[ cl*_p + col ] += data[k + i];
            }

            k += jn;
        }

        ntClass->releaseBlockOfRows( classesBlock );
        ntData->releaseSparseBlock( dataBlock );
    }
};

template<typename algorithmFPType, Method method, CpuType cpu>
void collectCounters( const Parameter *nbPar, NumericTable *ntData, NumericTable *ntClass,
                      algorithmFPType *n_c, algorithmFPType *n_ci, bool firstBlock )
{
    size_t p = ntData->getNumberOfColumns();
    size_t n = ntData->getNumberOfRows();
    size_t c = nbPar->nClasses;

    daal::tls<algorithmFPType *> tls_n_ci( [ = ]()-> algorithmFPType * { return _CALLOC_<algorithmFPType, cpu>(p * c); } );

    daal::threader_for_blocked( n, n, [ =, &tls_n_ci](algorithmFPType j0, algorithmFPType jn)
    {
        algorithmFPType *local_n_ci = tls_n_ci.local();

        localDataCollector<algorithmFPType, method, cpu> ldc(p, c, ntData, ntClass, local_n_ci);

        algorithmFPType block_size = ldc.getBlockSize(jn);
        int i;

        for ( i = 0 ; i + block_size < jn + 1 ; i += block_size )
        {
            ldc.addData( j0+i, block_size );
        }

        if ( i != jn )
        {
            ldc.addData( j0+i, jn-i );
        }
    } );

    if( firstBlock )
    {
      PRAGMA_IVDEP
        for(size_t j=0;j<c;j++)
        {
            n_c[j] = 0;
        }

      PRAGMA_IVDEP
        for(size_t j=0;j<p*c;j++)
        {
            n_ci[j] = 0;
        }
    }

    tls_n_ci.reduce( [ = ](algorithmFPType * v)
    {
      PRAGMA_IVDEP
      PRAGMA_VECTOR_ALWAYS
      PRAGMA_VECTOR_ALIGNED
        for(size_t j=0;j<c;j++)
        {
            for(size_t i=0;i<p;i++)
            {
                n_ci[j*p+i] += v[j*p+i];
                n_c [j    ] += v[j*p+i];
            }
        }
        _FREE_<algorithmFPType, cpu>( v );
    } );
}

template<typename algorithmFPType, Method method, CpuType cpu>
void mergeModels( const Parameter *nbPar, size_t p, size_t nModels, PartialModel *const *models,
                  algorithmFPType *n_c, algorithmFPType *n_ci, size_t &merged_n )
{
    size_t c = nbPar->nClasses;

    for( size_t i = 0; i < nModels; i++ )
    {
        algorithmFPType *in_n_c;
        algorithmFPType *in_n_ci;

        BlockMicroTable<algorithmFPType, readOnly, cpu> mtC ( models[i]->getClassSize().get()     );
        BlockMicroTable<algorithmFPType, readOnly, cpu> mtCi( models[i]->getClassGroupSum().get() );

        mtC .getBlockOfRows( 0, c, &in_n_c  );
        mtCi.getBlockOfRows( 0, c, &in_n_ci );

        for( size_t j = 0; j < c; j++ )
        {
            n_c[j] += in_n_c[j];
        }

        for( size_t j = 0; j < p * c; j++ )
        {
            n_ci[j] += in_n_ci[j];
        }

        mtC .release();
        mtCi.release();

        merged_n += models[i]->getNObservations();
    }
}

template<typename algorithmFPType, Method method, CpuType cpu>
void fillModel( const Parameter *nbPar, size_t p, algorithmFPType *n_c, algorithmFPType *n_ci, Model *rMdl )
{
    size_t c = nbPar->nClasses;

    BlockMicroTable<algorithmFPType, writeOnly, cpu> mtLogP    ( rMdl->getLogP().get()     );
    BlockMicroTable<algorithmFPType, writeOnly, cpu> mtLogTheta( rMdl->getLogTheta().get() );
    BlockMicroTable<algorithmFPType, writeOnly, cpu> mtAuxTable( rMdl->getAuxTable().get() );

    algorithmFPType *log_p;
    algorithmFPType *log_theta;
    algorithmFPType *aux_table;

    mtLogP    .getBlockOfRows( 0, c, &log_p     );
    mtLogTheta.getBlockOfRows( 0, c, &log_theta );
    mtAuxTable.getBlockOfRows( 0, c, &aux_table );

    if ( !nbPar->priorClassEstimates.get() )
    {
        algorithmFPType log_p_const = -daal::internal::Math<algorithmFPType, cpu>::sLog( (algorithmFPType)c );

        for ( size_t j = 0; j < c; j++ )
        {
            log_p[j] = log_p_const;
        }
    }
    else
    {
        algorithmFPType *pe;
        BlockMicroTable<algorithmFPType, readOnly, cpu> mtPE( nbPar->priorClassEstimates.get() );
        mtPE.getBlockOfRows( 0, c, &pe );

        daal::internal::Math<algorithmFPType, cpu>::vLog(c, pe, log_p);

        mtPE.release();
    }

    if ( !nbPar->alpha.get() )
    {
        algorithmFPType alpha_i = 1;
        algorithmFPType alpha   = p * alpha_i;

        for ( size_t j = 0; j < c; j++ )
        {
            algorithmFPType denominator = (algorithmFPType)1.0 / (n_c [ j ] + alpha);

PRAGMA_SIMD_ASSERT
            for ( size_t i = 0 ; i < p; i++ )
            {
                log_theta[ j * p + i ] = (n_ci[ j * p + i ] + alpha_i) * denominator;
            }
            daal::internal::Math<algorithmFPType, cpu>::vLog(p, log_theta + j * p, log_theta + j * p);
        }
    }
    else
    {
        algorithmFPType *alpha_i;
        BlockMicroTable<algorithmFPType, readOnly, cpu> mtAlphaI( nbPar->alpha.get() );
        mtAlphaI.getBlockOfRows( 0, 1, &alpha_i );

        algorithmFPType alpha = 0;
        for ( size_t i = 0 ; i < p; i++ )
        {
            alpha += alpha_i[i];
        }

        for ( size_t j = 0; j < c; j++ )
        {
            algorithmFPType denominator = (algorithmFPType)1.0 / (n_c [ j ] + alpha);

          PRAGMA_SIMD_ASSERT
            for ( size_t i = 0 ; i < p; i++ )
            {
                log_theta[ j * p + i ] = (n_ci[ j * p + i ] + alpha_i[i]) * denominator;
            }
            daal::internal::Math<algorithmFPType, cpu>::vLog(p, log_theta + j * p, log_theta + j * p);
        }

        mtAlphaI.release();
    }

    for ( size_t j = 0; j < c; j++ )
    {
        for ( size_t i = 0 ; i < p; i++ )
        {
            aux_table[ j * p + i ] = log_theta[ j * p + i ] + log_p[j];
        }
    }

    mtLogP    .release();
    mtLogTheta.release();
    mtAuxTable.release();

    rMdl->setNFeatures( p );
}

template<typename algorithmFPType, Method method, CpuType cpu>
void NaiveBayesBatchTrainKernel<algorithmFPType, method, cpu>::compute(size_t na, const NumericTable *const *a,
                                                                       Model *mdl,
                                                                       const Parameter *nbPar)
{
    NumericTable *ntData  = const_cast<NumericTable *>( a[0] );
    NumericTable *ntClass = const_cast<NumericTable *>( a[1] );

    size_t p = ntData->getNumberOfColumns();
    size_t c = nbPar->nClasses;

    algorithmFPType *n_c  = (algorithmFPType *)daal::services::daal_malloc( c *     sizeof(algorithmFPType) );
    algorithmFPType *n_ci = (algorithmFPType *)daal::services::daal_malloc( c * p * sizeof(algorithmFPType) );

    if ( n_c == 0 || n_ci == 0 )
    {
        if (n_c ) { daal::services::daal_free(n_c ); }
        if (n_ci) { daal::services::daal_free(n_ci); }

        this->_errors->add(services::ErrorMemoryAllocationFailed);
        return;
    }

    collectCounters<algorithmFPType, method, cpu>( nbPar, ntData, ntClass, n_c, n_ci, true );
    fillModel<algorithmFPType, method, cpu>( nbPar, p, n_c, n_ci, mdl );

    daal::services::daal_free(n_c );
    daal::services::daal_free(n_ci);
}

template<typename algorithmFPType, Method method, CpuType cpu>
void NaiveBayesOnlineTrainKernel<algorithmFPType, method, cpu>::compute(size_t na, const NumericTable *const *a,
                                                                        PartialModel *mdl,
                                                                        const Parameter *nbPar)
{
    NumericTable *ntData     = const_cast<NumericTable *>( a[0] );
    NumericTable *ntClass    = const_cast<NumericTable *>( a[1] );

    size_t c = nbPar->nClasses;

    algorithmFPType *n_c ;
    algorithmFPType *n_ci;

    if( mdl->getNObservations() == 0 )
    {
        BlockMicroTable<algorithmFPType, writeOnly, cpu> mtC ( mdl->getClassSize().get()     );
        BlockMicroTable<algorithmFPType, writeOnly, cpu> mtCi( mdl->getClassGroupSum().get() );

        mtC .getBlockOfRows( 0, c, &n_c  );
        mtCi.getBlockOfRows( 0, c, &n_ci );

        collectCounters<algorithmFPType, method, cpu>( nbPar, ntData, ntClass, n_c, n_ci, true );

        mtC .release();
        mtCi.release();
    }
    else
    {
        BlockMicroTable<algorithmFPType, readWrite, cpu> mtC ( mdl->getClassSize().get()     );
        BlockMicroTable<algorithmFPType, readWrite, cpu> mtCi( mdl->getClassGroupSum().get() );

        mtC .getBlockOfRows( 0, c, &n_c  );
        mtCi.getBlockOfRows( 0, c, &n_ci );

        collectCounters<algorithmFPType, method, cpu>( nbPar, ntData, ntClass, n_c, n_ci, false );

        mtC .release();
        mtCi.release();
    }

    size_t n = ntData->getNumberOfRows();

    mdl->setNObservations( mdl->getNObservations() + n );
    mdl->setNFeatures( ntData->getNumberOfColumns() );
}

template<typename algorithmFPType, Method method, CpuType cpu>
void NaiveBayesOnlineTrainKernel<algorithmFPType, method, cpu>::finalizeCompute(PartialModel *pMdl,
                                                                                Model *rMdl,
                                                                                const Parameter *nbPar)
{
    size_t c = nbPar->nClasses;

    algorithmFPType *n_c ;
    algorithmFPType *n_ci;

    BlockMicroTable<algorithmFPType, readWrite, cpu> mtC ( pMdl->getClassSize().get()     );
    BlockMicroTable<algorithmFPType, readWrite, cpu> mtCi( pMdl->getClassGroupSum().get() );

    mtC .getBlockOfRows( 0, c, &n_c  );
    mtCi.getBlockOfRows( 0, c, &n_ci );

    fillModel<algorithmFPType, method, cpu>( nbPar, pMdl->getNFeatures(), n_c, n_ci, rMdl );

    mtC .release();
    mtCi.release();
}

template<typename algorithmFPType, Method method, CpuType cpu>
void NaiveBayesDistributedTrainKernel<algorithmFPType, method, cpu>::merge(size_t nModels, PartialModel *const *inPMdls,
                                                                           PartialModel *outPMdl,
                                                                           const Parameter *nbPar)
{
    size_t c = nbPar->nClasses;
    size_t p = outPMdl->getNFeatures();

    algorithmFPType *n_c ;
    algorithmFPType *n_ci;

    size_t merged_n = 0;

    if( outPMdl->getNObservations() == 0 )
    {
        BlockMicroTable<algorithmFPType, writeOnly, cpu> mtC ( outPMdl->getClassSize().get()     );
        BlockMicroTable<algorithmFPType, writeOnly, cpu> mtCi( outPMdl->getClassGroupSum().get() );

        mtC .getBlockOfRows( 0, c, &n_c  );
        mtCi.getBlockOfRows( 0, c, &n_ci );

        for( size_t j = 0; j < c; j++ )
        {
            n_c[j] = 0;
        }

        for( size_t j = 0; j < p * c; j++ )
        {
            n_ci[j] = 0;
        }

        mergeModels<algorithmFPType, method, cpu>( nbPar, p, nModels, inPMdls, n_c, n_ci, merged_n );

        mtC .release();
        mtCi.release();
    }
    else
    {
        BlockMicroTable<algorithmFPType, readWrite, cpu> mtC ( outPMdl->getClassSize().get()     );
        BlockMicroTable<algorithmFPType, readWrite, cpu> mtCi( outPMdl->getClassGroupSum().get() );

        mtC .getBlockOfRows( 0, c, &n_c  );
        mtCi.getBlockOfRows( 0, c, &n_ci );

        mergeModels<algorithmFPType, method, cpu>( nbPar, p, nModels, inPMdls, n_c, n_ci, merged_n );

        mtC .release();
        mtCi.release();
    }

    outPMdl->setNObservations( outPMdl->getNObservations() + merged_n );
}

} // namespace internal
} // namespace training
} // namespace multinomial_naive_bayes
} // namespace algorithms
} // namespace daal

#endif
